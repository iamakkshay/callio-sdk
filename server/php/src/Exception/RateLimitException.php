<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Exception;

/** 429: the organisation's request rate is exceeded. getRetryAfter() is in seconds, from the Retry-After header. */
class RateLimitException extends CallioException
{
    public function __construct(string $message, int $status = 429, mixed $body = null, ?string $request = null, private readonly ?float $retryAfter = null)
    {
        parent::__construct($message, $status, $body, $request);
    }

    public function getRetryAfter(): ?float
    {
        return $this->retryAfter;
    }
}
