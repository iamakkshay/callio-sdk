<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Transport;

/** No response arrived. */
final class TransportException extends \RuntimeException
{
    public function __construct(string $message, private readonly bool $timedOut = false)
    {
        parent::__construct($message);
    }

    public function isTimeout(): bool
    {
        return $this->timedOut;
    }
}
