<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Transport;

/** A response. For a request with a sink, a 2xx body went to the sink and `$body` is empty. */
final class Response
{
    /** @var array<string, list<string>> lower-cased names */
    private array $headers = [];

    /** @param array<string, string|list<string>> $headers */
    public function __construct(public readonly int $status, array $headers = [], public readonly string $body = '')
    {
        foreach ($headers as $k => $v) {
            $this->headers[strtolower((string) $k)] = is_array($v) ? array_values($v) : [$v];
        }
    }

    public function header(string $name): ?string
    {
        return $this->headers[strtolower($name)][0] ?? null;
    }

    /** @return array<string, list<string>> */
    public function headers(): array
    {
        return $this->headers;
    }
}
