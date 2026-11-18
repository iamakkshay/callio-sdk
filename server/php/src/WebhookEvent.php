<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio;

/**
 * A verified webhook event: array access to every field (`$event['order']['agent']`) plus shortcuts.
 *
 * Types: order.created | order.assigned | order.closed | order.reopened (`order`, `by`); call.* / chat.* /
 * location.* (`callId`, `from`, `to`, `payload`); recording.ready (`recordingId`, `durationSec`,
 * `retainUntil`; never audio); cc.chat-escalated (`interaction`, `transcriptUrl`); report.snapshot (`kpis`,
 * `series`). New types may be added; ignore ones you don't handle.
 *
 * @implements \ArrayAccess<string, mixed>
 */
final class WebhookEvent implements \ArrayAccess, \JsonSerializable
{
    /** @param array<string, mixed> $data */
    public function __construct(private readonly array $data)
    {
    }

    /** Unique per event: use it to drop duplicates (store the ids you have handled). */
    public function id(): ?string
    {
        return isset($this->data['id']) ? (string) $this->data['id'] : null;
    }

    public function type(): string
    {
        return (string) $this->data['type'];
    }

    public function tenantId(): ?string
    {
        return $this->data['tenantId'] ?? null;
    }

    public function at(): ?string
    {
        return $this->data['at'] ?? null;
    }

    public function isOrderEvent(): bool
    {
        return str_starts_with($this->type(), 'order.');
    }

    public function isRecordingReady(): bool
    {
        return $this->type() === 'recording.ready';
    }

    /** @return array<string, mixed> */
    public function toArray(): array
    {
        return $this->data;
    }

    public function offsetExists(mixed $offset): bool
    {
        return isset($this->data[$offset]);
    }

    public function offsetGet(mixed $offset): mixed
    {
        return $this->data[$offset] ?? null;
    }

    public function offsetSet(mixed $offset, mixed $value): void
    {
        throw new \LogicException('Callio: a webhook event is read-only');
    }

    public function offsetUnset(mixed $offset): void
    {
        throw new \LogicException('Callio: a webhook event is read-only');
    }

    /** @return array<string, mixed> */
    public function jsonSerialize(): array
    {
        return $this->data;
    }
}
