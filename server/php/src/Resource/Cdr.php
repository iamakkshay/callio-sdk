<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Resource;

/** Call records. */
final class Cdr extends Resource
{
    /**
     * Call records for the last `days` (1–90, default 7): one row per call.
     *
     * @param array{days?: int, type?: 'customer'|'agent'|'guest'} $params
     * @return array{days: int, calls: list<array<string, mixed>>}
     */
    public function list(array $params = []): array
    {
        return $this->http->request('GET', '/api/v1/cdr', $params);
    }
}
