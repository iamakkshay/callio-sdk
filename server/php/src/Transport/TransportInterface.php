<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Transport;

/**
 * The one place a request leaves the process. The default is CurlTransport; replace it for tests, proxies or
 * instrumentation. A transport must not follow redirects.
 */
interface TransportInterface
{
    /**
     * @param array<string, string> $headers
     * @param resource|null $sink when given, a 2xx response body is streamed into it (the timeout then covers
     *                            getting the response headers only); other bodies are returned in Response::$body
     * @throws TransportException when no response arrived (isTimeout() for a timeout)
     */
    public function send(string $method, string $url, #[\SensitiveParameter] array $headers, ?string $body, float $timeout, $sink = null): Response;
}
