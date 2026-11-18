<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio;

use Clarigoinfotech\Callio\Exception\CallioException;
use Clarigoinfotech\Callio\Exception\ConnectionException;
use Clarigoinfotech\Callio\Exception\RedirectException;
use Clarigoinfotech\Callio\Exception\TimeoutException;
use Clarigoinfotech\Callio\Transport\CurlTransport;
use Clarigoinfotech\Callio\Transport\Response;
use Clarigoinfotech\Callio\Transport\TransportException;
use Clarigoinfotech\Callio\Transport\TransportInterface;

/**
 * The HTTP layer: a timeout per attempt, and retries with exponential backoff for idempotent requests (GET,
 * HEAD, PUT, DELETE, OPTIONS) on 429, 5xx and network errors. Redirects are never followed. The API key only
 * goes into the Authorization header; it is never in an error, a URL, var_dump() or json_encode().
 */
final class HttpClient implements \JsonSerializable
{
    private const IDEMPOTENT = ['GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS'];

    /** @var \Closure(int, ?float): float seconds to wait before retry $attempt + 1 */
    private \Closure $backoff;
    /** @var \Closure(float): void */
    private \Closure $sleep;
    private readonly TransportInterface $transport;

    public function __construct(
        #[\SensitiveParameter] private readonly string $apiKey,
        public readonly string $baseUrl,
        public readonly float $timeout,
        public readonly int $maxRetries,
        public readonly string $userAgent,
        ?TransportInterface $transport = null,
    ) {
        $this->transport = $transport ?? new CurlTransport();
        $this->backoff = static function (int $attempt, ?float $retryAfter): float {
            if ($retryAfter !== null) {
                return min($retryAfter, 60.0);
            }
            return min(8.0, 0.5 * 2 ** $attempt) * (0.5 + mt_rand() / mt_getrandmax() / 2);
        };
        $this->sleep = static function (float $seconds): void {
            if ($seconds > 0) {
                usleep((int) round($seconds * 1e6));
            }
        };
    }

    /** Replace the retry backoff: fn(int $attempt, ?float $retryAfterSeconds): float seconds. */
    public function setBackoff(callable $backoff): void
    {
        $this->backoff = \Closure::fromCallable($backoff);
    }

    /** Replace the sleep between retries (tests). */
    public function setSleep(callable $sleep): void
    {
        $this->sleep = \Closure::fromCallable($sleep);
    }

    /** @return array<string, mixed> never the key */
    public function __debugInfo(): array
    {
        return ['baseUrl' => $this->baseUrl, 'timeout' => $this->timeout, 'maxRetries' => $this->maxRetries];
    }

    /** @return array<string, mixed> never the key */
    public function jsonSerialize(): array
    {
        return $this->__debugInfo();
    }

    public function __serialize(): array
    {
        throw new \LogicException('Callio: the client holds an API key and cannot be serialised');
    }

    /** @param array<string, mixed>|null $query */
    public static function encodeQuery(?array $query): string
    {
        if (!$query) {
            return '';
        }
        $parts = [];
        foreach ($query as $k => $v) {
            if ($v === null || $v === '' || $v === []) {
                continue;
            }
            if (is_array($v)) {
                $v = implode(',', array_map('strval', $v));
            } elseif (is_bool($v)) {
                $v = $v ? 'true' : 'false';
            } elseif ($v instanceof \DateTimeInterface) {
                $v = \DateTimeImmutable::createFromInterface($v)->setTimezone(new \DateTimeZone('UTC'))->format('Y-m-d\TH:i:s.v\Z');
            }
            $parts[] = urlencode((string) $k) . '=' . urlencode((string) $v);
        }
        return $parts ? '?' . implode('&', $parts) : '';
    }

    /** Seconds from a Retry-After header (seconds or an HTTP date), or null. */
    public static function parseRetryAfter(?string $h): ?float
    {
        if ($h === null || trim($h) === '') {
            return null;
        }
        $h = trim($h);
        if (is_numeric($h)) {
            $n = (float) $h;
            return $n >= 0 && is_finite($n) ? $n : null;
        }
        $t = strtotime($h);
        return $t === false ? null : (float) max(0, (int) ceil($t - microtime(true)));
    }

    /**
     * Send a request and return the decoded JSON (arrays), or null for an empty body.
     *
     * @param array<string, mixed>|null $query
     */
    public function request(string $method, string $path, ?array $query = null, mixed $body = null): mixed
    {
        $res = $this->send($method, $path, $query, $body, null);
        return self::decode($res->body);
    }

    /**
     * Send a GET (or other) request and stream a 2xx body into $sink (a writable stream resource).
     *
     * @param array<string, mixed>|null $query
     * @param resource $sink
     */
    public function requestStream(string $method, string $path, ?array $query, $sink): Response
    {
        if (!is_resource($sink)) {
            throw new \InvalidArgumentException('Callio: the sink must be a writable stream resource');
        }
        return $this->send($method, $path, $query, null, $sink);
    }

    /** @param resource|null $sink */
    private function send(string $method, string $path, ?array $query, mixed $body, $sink): Response
    {
        $method = strtoupper($method);
        $url = $this->baseUrl . $path . self::encodeQuery($query);
        $label = $method . ' ' . $path;
        $headers = [
            'Authorization' => 'Bearer ' . $this->apiKey,
            'Accept' => $sink !== null ? '*/*' : 'application/json',
            'User-Agent' => $this->userAgent,
        ];
        $payload = null;
        if ($body !== null) {
            $headers['Content-Type'] = 'application/json';
            $payload = json_encode($body === [] ? new \stdClass() : $body, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR | JSON_PRESERVE_ZERO_FRACTION);
        }
        $retryable = in_array($method, self::IDEMPOTENT, true);
        $sinkStart = $sink !== null ? ftell($sink) : false;

        for ($attempt = 0; ; $attempt++) {
            try {
                $res = $this->transport->send($method, $url, $headers, $payload, $this->timeout, $sink);
            } catch (TransportException $e) {
                $err = $e->isTimeout()
                    ? new TimeoutException(sprintf('Callio: no response within %s s (%s)', $this->timeout, $label), 0, null, $label)
                    : new ConnectionException(sprintf('Callio: could not reach %s (%s): %s', $this->baseUrl, $label, $e->getMessage()), 0, null, $label);
                if ($retryable && $attempt < $this->maxRetries) {
                    $this->rewind($sink, $sinkStart);
                    ($this->sleep)(($this->backoff)($attempt, null));
                    continue;
                }
                throw $err;
            }
            $st = $res->status;
            if ($st >= 200 && $st < 300) {
                return $res;
            }
            if ($st >= 300 && $st < 400) {
                $where = 'another location';
                $loc = parse_url((string) $res->header('Location'));
                if (is_array($loc) && isset($loc['host'])) {
                    $where = ($loc['scheme'] ?? 'https') . '://' . $loc['host'] . (isset($loc['port']) ? ':' . $loc['port'] : '');
                }
                throw new RedirectException("Callio: refusing to follow a redirect to {$where} (the API key is never sent on a redirect); check the base URL", $st, null, $label);
            }
            $retryAfter = self::parseRetryAfter($res->header('Retry-After'));
            if ($retryable && ($st === 429 || $st >= 500) && $attempt < $this->maxRetries) {
                ($this->sleep)(($this->backoff)($attempt, $retryAfter));
                continue;
            }
            $parsed = self::decode($res->body);
            if (is_array($parsed) && is_string($parsed['error'] ?? null)) {
                $msg = $parsed['error'];
            } elseif (is_string($parsed) && $parsed !== '') {
                $msg = mb_substr($parsed, 0, 200);
            } else {
                $msg = 'HTTP ' . $st;
            }
            throw CallioException::forStatus($st, $msg, $parsed, $label, $retryAfter);
        }
    }

    /** @param resource|null $sink */
    private function rewind($sink, int|false $start): void
    {
        if ($sink !== null && $start !== false) {
            @ftruncate($sink, $start);
            @fseek($sink, $start);
        }
    }

    private static function decode(string $raw): mixed
    {
        if ($raw === '') {
            return null;
        }
        try {
            return json_decode($raw, true, 512, JSON_THROW_ON_ERROR | JSON_BIGINT_AS_STRING);
        } catch (\JsonException) {
            return $raw;
        }
    }
}
