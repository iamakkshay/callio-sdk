<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Tests;

use Clarigoinfotech\Callio\Transport\Response;
use Clarigoinfotech\Callio\Transport\TransportInterface;

/** A scripted transport: each call takes the next responder. */
final class MockTransport implements TransportInterface
{
    /** @var list<array{method: string, url: string, headers: array<string, string>, body: ?string, timeout: float, stream: bool}> */
    public array $calls = [];
    /** @var list<callable|Response> */
    private array $responses;

    public function __construct(callable|Response ...$responses)
    {
        $this->responses = $responses;
    }

    public function send(string $method, string $url, #[\SensitiveParameter] array $headers, ?string $body, float $timeout, $sink = null): Response
    {
        $this->calls[] = ['method' => $method, 'url' => $url, 'headers' => $headers, 'body' => $body, 'timeout' => $timeout, 'stream' => $sink !== null];
        if (!$this->responses) {
            throw new \LogicException("unexpected request {$url}");
        }
        $r = array_shift($this->responses);
        $res = $r instanceof Response ? $r : $r($method, $url);
        if ($sink !== null && $res->status >= 200 && $res->status < 300) {
            fwrite($sink, $res->body);
            return new Response($res->status, $res->headers(), '');
        }
        return $res;
    }

    public function json(int $i): mixed
    {
        $b = $this->calls[$i]['body'];
        return $b === null ? null : json_decode($b, true);
    }

    public function query(int $i, string $name): ?string
    {
        parse_str((string) parse_url($this->calls[$i]['url'], PHP_URL_QUERY), $q);
        return $q[$name] ?? null;
    }

    public static function json_(int $status, mixed $body, array $headers = []): Response
    {
        return new Response($status, ['Content-Type' => 'application/json'] + $headers, $body === null ? '' : json_encode($body));
    }
}
