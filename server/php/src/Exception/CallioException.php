<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Exception;

/**
 * Every failure from the API: the HTTP status and the server's `{"error": "<reason>"}` message. Subclasses
 * let callers branch with `catch`. Never contains the API key.
 */
class CallioException extends \RuntimeException
{
    /**
     * @param int $status HTTP status; 0 when no response arrived (network failure or timeout)
     * @param mixed $body the parsed response body, when there was one
     * @param string|null $request the method and path, e.g. "GET /api/v1/orders/X" (never the key)
     */
    public function __construct(string $message, private readonly int $status = 0, private readonly mixed $body = null, private readonly ?string $request = null)
    {
        parent::__construct($message, $status);
    }

    public function getStatus(): int
    {
        return $this->status;
    }

    public function getBody(): mixed
    {
        return $this->body;
    }

    public function getRequest(): ?string
    {
        return $this->request;
    }

    public static function forStatus(int $status, string $message, mixed $body, string $request, ?float $retryAfter = null): self
    {
        return match (true) {
            $status === 400, $status === 422 => new ValidationException($message, $status, $body, $request),
            $status === 401 => new AuthenticationException($message, $status, $body, $request),
            $status === 403 => new PermissionDeniedException($message, $status, $body, $request),
            $status === 404 => new NotFoundException($message, $status, $body, $request),
            $status === 409 => new ConflictException($message, $status, $body, $request),
            $status === 410 => new GoneException($message, $status, $body, $request),
            $status === 429 => new RateLimitException($message, $status, $body, $request, $retryAfter),
            $status >= 300 && $status < 400 => new RedirectException($message, $status, $body, $request),
            $status >= 500 => new ServerException($message, $status, $body, $request),
            default => new self($message, $status, $body, $request),
        };
    }
}
