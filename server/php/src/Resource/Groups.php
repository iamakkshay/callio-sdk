<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Resource;

/** Group chats: 2–50 members. A group is an array: id, name, createdAt, members (username, displayName, userType, sipUser). */
final class Groups extends Resource
{
    /**
     * @param array{id: string, name: string, members: list<string>} $params
     * @return array<string, mixed>
     */
    public function create(array $params): array
    {
        return $this->http->request('POST', '/api/v1/groups', null, $params)['group'];
    }

    /** @return list<array<string, mixed>> */
    public function list(): array
    {
        return $this->http->request('GET', '/api/v1/groups')['groups'];
    }

    /** @return array<string, mixed> */
    public function get(string $id): array
    {
        return $this->http->request('GET', '/api/v1/groups/' . self::seg($id))['group'];
    }

    /**
     * Rename, add or remove members. Members added later see messages from when they joined.
     *
     * @param array{name?: string, add?: list<string>, remove?: list<string>} $params
     * @return array<string, mixed>
     */
    public function update(string $id, array $params): array
    {
        return $this->http->request('PATCH', '/api/v1/groups/' . self::seg($id), null, $params)['group'];
    }

    /**
     * Deletes the group and its messages.
     *
     * @return array{ok: true}
     */
    public function delete(string $id): array
    {
        return $this->http->request('DELETE', '/api/v1/groups/' . self::seg($id));
    }
}
