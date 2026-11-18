<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Resource;

/**
 * Orders: which customer and which agent belong together right now. An order is an array: id, customer, agent
 * (null when unassigned), status (active | closed), label, createdAt, updatedAt, closedAt.
 */
final class Orders extends Resource
{
    /**
     * ConflictException if the id exists, ValidationException for an unknown customer/agent or a wrong user type.
     *
     * @param array{id: string, customer: string, agent?: string, label?: string} $params
     * @return array<string, mixed>
     */
    public function create(array $params): array
    {
        return $this->http->request('POST', '/api/v1/orders', null, $params)['order'];
    }

    /**
     * @param array{status?: 'active'|'closed', user?: string, limit?: int} $params
     * @return list<array<string, mixed>>
     */
    public function list(array $params = []): array
    {
        return $this->http->request('GET', '/api/v1/orders', $params)['orders'];
    }

    /** @return array<string, mixed> */
    public function get(string $id): array
    {
        return $this->http->request('GET', '/api/v1/orders/' . self::seg($id))['order'];
    }

    /**
     * Reassign (`agent`), unassign (`'agent' => null`), close or reopen (`status`), relabel.
     *
     * @param array{agent?: string|null, status?: 'active'|'closed', label?: string|null} $params
     * @return array<string, mixed>
     */
    public function update(string $id, array $params): array
    {
        return $this->http->request('PATCH', '/api/v1/orders/' . self::seg($id), null, $params)['order'];
    }

    /** Assign an agent; null unassigns. @return array<string, mixed> */
    public function assign(string $id, ?string $agent): array
    {
        return $this->update($id, ['agent' => $agent]);
    }

    /** @return array<string, mixed> */
    public function close(string $id): array
    {
        return $this->update($id, ['status' => 'closed']);
    }

    /** @return array<string, mixed> */
    public function reopen(string $id): array
    {
        return $this->update($id, ['status' => 'active']);
    }
}
