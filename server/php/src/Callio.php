<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio;

use Clarigoinfotech\Callio\Exception\CallioException;
use Clarigoinfotech\Callio\Resource\Cdr;
use Clarigoinfotech\Callio\Resource\Events;
use Clarigoinfotech\Callio\Resource\Groups;
use Clarigoinfotech\Callio\Resource\Orders;
use Clarigoinfotech\Callio\Resource\Recordings;
use Clarigoinfotech\Callio\Resource\Tokens;
use Clarigoinfotech\Callio\Resource\Users;
use Clarigoinfotech\Callio\Transport\TransportInterface;

/**
 * The Callio tenant API client. Keep it on your server: the API key gives full access to your organisation's
 * users, orders and recordings.
 *
 *     $callio = new Callio(apiKey: getenv('CALLIO_API_KEY'), baseUrl: 'https://api.example.sa');
 *     $t = $callio->tokens->forUser('cust-42', ['displayName' => 'Sara', 'userType' => 'customer']);
 */
final class Callio implements \JsonSerializable
{
    public readonly Users $users;
    public readonly Tokens $tokens;
    public readonly Orders $orders;
    public readonly Recordings $recordings;
    public readonly Groups $groups;
    public readonly Events $events;
    public readonly Cdr $cdr;
    /** The underlying HTTP client (request() for endpoints the SDK doesn't wrap yet). */
    public readonly HttpClient $http;

    /**
     * @param string|null $apiKey the tenant API key, cio_<id>_<secret>; defaults to CALLIO_API_KEY
     * @param string|null $baseUrl your Callio host, e.g. https://api.example.sa; defaults to CALLIO_BASE_URL
     * @param float $timeout seconds per attempt
     * @param int $maxRetries retries for idempotent requests on 429 / 5xx / network errors
     * @param string|null $userAgent appended to the User-Agent, e.g. "my-backend/1.4"
     * @param bool $allowInsecure permit an http:// base URL (a local stack only: the key travels in clear text)
     * @param TransportInterface|null $transport replace the HTTP transport (tests, proxies)
     */
    public function __construct(
        #[\SensitiveParameter] ?string $apiKey = null,
        ?string $baseUrl = null,
        float $timeout = 30.0,
        int $maxRetries = 2,
        ?string $userAgent = null,
        bool $allowInsecure = false,
        ?TransportInterface $transport = null,
    ) {
        $apiKey = $apiKey !== null && $apiKey !== '' ? $apiKey : (getenv('CALLIO_API_KEY') ?: null);
        $baseUrl = $baseUrl !== null && $baseUrl !== '' ? $baseUrl : (getenv('CALLIO_BASE_URL') ?: null);
        if ($apiKey === null) {
            throw new CallioException('Callio: apiKey is required (or set CALLIO_API_KEY)');
        }
        if ($baseUrl === null) {
            throw new CallioException('Callio: baseUrl is required (or set CALLIO_BASE_URL), e.g. https://api.example.sa');
        }
        $https = preg_match('#^https://[^/]#i', $baseUrl) === 1;
        $http = preg_match('#^http://[^/]#i', $baseUrl) === 1;
        if (!$https && !($allowInsecure && $http)) {
            throw new CallioException('Callio: baseUrl must start with https:// (http:// only with allowInsecure: true, for a local stack)');
        }
        if ($timeout <= 0) {
            throw new CallioException('Callio: timeout must be positive');
        }
        $ua = 'callio-server-php/' . Version::VERSION . ' php/' . PHP_VERSION . ($userAgent ? ' ' . $userAgent : '');
        $this->http = new HttpClient($apiKey, rtrim($baseUrl, '/'), $timeout, max(0, $maxRetries), $ua, $transport);
        $this->users = new Users($this->http);
        $this->tokens = new Tokens($this->http, $this->users);
        $this->orders = new Orders($this->http);
        $this->recordings = new Recordings($this->http);
        $this->groups = new Groups($this->http);
        $this->events = new Events($this->http);
        $this->cdr = new Cdr($this->http);
    }

    /** @return array<string, mixed> never the key */
    public function __debugInfo(): array
    {
        return ['baseUrl' => $this->http->baseUrl];
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
}
