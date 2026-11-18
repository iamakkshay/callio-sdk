<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio;

use Clarigoinfotech\Callio\Exception\WebhookVerificationException;

/**
 * Webhook verification. Callio POSTs JSON events to the organisation's webhook URL and signs them with the
 * webhook secret:
 *
 *     X-Callio-Timestamp: <unix seconds>
 *     X-Callio-Signature: v1=<hex HMAC-SHA256(secret, timestamp + "." + rawBody)>
 *     X-NGX-Signature:    sha256=<hex HMAC-SHA256(secret, rawBody)>   (legacy, no replay protection)
 *
 * verifyRequest() / parseRequest() check the v1 signature and that the timestamp is within a tolerance
 * (default 5 minutes), so a captured request cannot be replayed later. Verify the exact bytes received
 * (`file_get_contents('php://input')`, `$request->getContent()`): re-serialising parsed JSON changes them.
 * Each event carries a unique `id`.
 */
final class Webhook
{
    public const SIGNATURE_HEADER = 'X-NGX-Signature';
    public const TIMESTAMP_HEADER = 'X-Callio-Timestamp';
    public const SIGNATURE_V1_HEADER = 'X-Callio-Signature';
    public const DEFAULT_TOLERANCE = 300;

    /** The legacy `sha256=<hex>` value for this body. */
    public static function sign(string $rawBody, #[\SensitiveParameter] string $secret): string
    {
        self::requireSecret($secret);
        return 'sha256=' . hash_hmac('sha256', $rawBody, $secret);
    }

    /** The `v1=<hex>` value Callio sends in X-Callio-Signature for this body and timestamp. */
    public static function signV1(string $rawBody, int $timestamp, #[\SensitiveParameter] string $secret): string
    {
        self::requireSecret($secret);
        return 'v1=' . hash_hmac('sha256', $timestamp . '.' . $rawBody, $secret);
    }

    /**
     * The legacy check: $signatureHeader (X-NGX-Signature) is the HMAC-SHA256 of $rawBody. Constant-time; false
     * for a missing or malformed header.
     *
     * @deprecated cannot detect a replayed request; use verifyRequest() with the request headers
     * @param string|list<string>|null $signatureHeader
     */
    public static function verify(string $rawBody, string|array|null $signatureHeader, #[\SensitiveParameter] string $secret): bool
    {
        self::requireSecret($secret);
        return self::matches('sha256', self::first($signatureHeader), hash_hmac('sha256', $rawBody, $secret));
    }

    /**
     * Check a webhook request. Passes when X-Callio-Signature is valid for `X-Callio-Timestamp + "." + rawBody`
     * and the timestamp is within the tolerance; otherwise throws WebhookVerificationException (status 401). A
     * request without a timestamp is rejected unless `allowLegacy` is set (then X-NGX-Signature is checked).
     *
     * @param array<string, string|list<string>> $headers any case: getallheaders(), Laravel/Symfony
     *        `$request->headers->all()`, PSR-7 `getHeaders()`, or $_SERVER (HTTP_X_CALLIO_TIMESTAMP…)
     * @param array{tolerance?: int, allowLegacy?: bool, now?: int} $options tolerance in seconds (default 300);
     *        allowLegacy accepts body-only signatures (replayable); now replaces the clock (tests)
     */
    public static function verifyRequest(string $rawBody, array $headers, #[\SensitiveParameter] string $secret, array $options = []): void
    {
        self::requireSecret($secret);
        $tolerance = (int) ($options['tolerance'] ?? self::DEFAULT_TOLERANCE);
        if ($tolerance <= 0) {
            throw new \InvalidArgumentException('Callio: the tolerance must be positive');
        }
        $ts = self::header($headers, self::TIMESTAMP_HEADER);
        $ts = $ts === null ? null : trim($ts);
        if ($ts === null || $ts === '') {
            if (empty($options['allowLegacy'])) {
                throw new WebhookVerificationException('Callio webhook: missing ' . self::TIMESTAMP_HEADER . ' (set allowLegacy to accept body-only signatures)', 401);
            }
            if (!self::matches('sha256', self::header($headers, self::SIGNATURE_HEADER), hash_hmac('sha256', $rawBody, $secret))) {
                throw new WebhookVerificationException('Callio webhook: bad or missing ' . self::SIGNATURE_HEADER, 401);
            }
            return;
        }
        if (!preg_match('/^\d{1,12}$/', $ts)) {
            throw new WebhookVerificationException('Callio webhook: malformed ' . self::TIMESTAMP_HEADER, 401);
        }
        // The signature first, so a forged timestamp gets the same answer as a forged body.
        if (!self::matches('v1', self::header($headers, self::SIGNATURE_V1_HEADER), hash_hmac('sha256', $ts . '.' . $rawBody, $secret))) {
            throw new WebhookVerificationException('Callio webhook: bad or missing ' . self::SIGNATURE_V1_HEADER, 401);
        }
        $now = (int) ($options['now'] ?? time());
        if (abs($now - (int) $ts) > $tolerance) {
            throw new WebhookVerificationException("Callio webhook: timestamp outside the {$tolerance} s tolerance (replayed or clock skew)", 401);
        }
    }

    /**
     * Verify the request (see verifyRequest()) and parse the event.
     *
     * @param array<string, string|list<string>> $headers
     * @param array{tolerance?: int, allowLegacy?: bool, now?: int} $options
     */
    public static function parseRequest(string $rawBody, array $headers, #[\SensitiveParameter] string $secret, array $options = []): WebhookEvent
    {
        self::verifyRequest($rawBody, $headers, $secret, $options);
        return self::decode($rawBody);
    }

    /**
     * Verify the legacy X-NGX-Signature and parse the event.
     *
     * @deprecated cannot detect a replayed request; use parseRequest() with the request headers
     * @param string|list<string>|null $signatureHeader
     */
    public static function parse(string $rawBody, string|array|null $signatureHeader, #[\SensitiveParameter] string $secret): WebhookEvent
    {
        if (!self::verify($rawBody, $signatureHeader, $secret)) {
            throw new WebhookVerificationException('Callio webhook: bad or missing ' . self::SIGNATURE_HEADER, 401);
        }
        return self::decode($rawBody);
    }

    private static function decode(string $rawBody): WebhookEvent
    {
        try {
            $ev = json_decode($rawBody, true, 512, JSON_THROW_ON_ERROR | JSON_BIGINT_AS_STRING);
        } catch (\JsonException) {
            throw new WebhookVerificationException('Callio webhook: the body is not JSON', 400);
        }
        if (!is_array($ev) || !is_string($ev['type'] ?? null)) {
            throw new WebhookVerificationException('Callio webhook: no event type', 400);
        }
        return new WebhookEvent($ev);
    }

    private static function requireSecret(string $secret): void
    {
        if ($secret === '') {
            throw new \InvalidArgumentException('Callio: the webhook secret is required');
        }
    }

    /** Any comma-separated `<scheme>=<hex>` in $header (secret rotation) equal to $wantHex, in constant time. */
    private static function matches(string $scheme, ?string $header, string $wantHex): bool
    {
        if ($header === null) {
            return false;
        }
        $ok = false;
        foreach (explode(',', $header) as $part) {
            if (preg_match('/^' . $scheme . '=([0-9a-fA-F]{64})$/D', trim($part), $m) && hash_equals($wantHex, strtolower($m[1]))) {
                $ok = true;
            }
        }
        return $ok;
    }

    /** @param string|list<string>|null $v */
    private static function first(string|array|null $v): ?string
    {
        if (is_array($v)) {
            $v = $v[0] ?? null;
        }
        return $v === null ? null : (string) $v;
    }

    /** @param array<string, mixed> $headers */
    private static function header(array $headers, string $name): ?string
    {
        $server = 'HTTP_' . strtoupper(str_replace('-', '_', $name));
        foreach ($headers as $k => $v) {
            if (strcasecmp((string) $k, $name) === 0 || $k === $server) {
                return self::first(is_array($v) ? array_values($v) : (string) $v);
            }
        }
        return null;
    }
}
