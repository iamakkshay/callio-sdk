<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Resource;

use Clarigoinfotech\Callio\HttpClient;

/** @internal */
abstract class Resource
{
    public function __construct(protected readonly HttpClient $http)
    {
    }

    /** A path segment: required, never "." or "..", percent-encoded. */
    protected static function seg(string $s): string
    {
        if ($s === '' || $s === '.' || $s === '..') {
            throw new \InvalidArgumentException('Callio: an id / username is required (and cannot be "." or "..")');
        }
        return rawurlencode($s);
    }

    protected static function reason(string $r): string
    {
        $r = trim($r);
        if (mb_strlen($r) < 5) {
            throw new \InvalidArgumentException('Callio: a reason of at least 5 characters is required to fetch a recording');
        }
        return $r;
    }

    /**
     * @param array<string, mixed> $params
     * @param list<string> $allowed
     * @return array<string, mixed>
     */
    protected static function pick(array $params, array $allowed): array
    {
        return array_intersect_key($params, array_flip($allowed));
    }
}
