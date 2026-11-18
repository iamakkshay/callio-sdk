<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Resource;

/**
 * App users. A user is an array: username, displayName, userType (customer | agent | guest), extension (SIP),
 * segment, disabled, phone (masked; not in list results).
 */
final class Users extends Resource
{
    /**
     * Search users.
     *
     * @param array{q?: string, type?: 'customer'|'agent', status?: 'active'|'disabled', segment?: string, limit?: int} $params
     * @return list<array<string, mixed>>
     */
    public function list(array $params = []): array
    {
        return $this->http->request('GET', '/api/v1/users', $params)['users'];
    }

    /**
     * Create a user. ConflictException (409) if the username exists, PermissionDeniedException (403) at the seat
     * quota. The result has `initialPassword` once, when no loginPassword was given.
     *
     * @param array{username: string, displayName?: string, userType?: 'customer'|'agent', loginPassword?: string, phone?: string} $params
     * @return array<string, mixed>
     */
    public function create(array $params): array
    {
        return $this->http->request('POST', '/api/v1/users', null, $params)['user'];
    }

    /** @return array<string, mixed> */
    public function get(string $username): array
    {
        return $this->http->request('GET', '/api/v1/users/' . self::seg($username))['user'];
    }

    /**
     * Changing the type or disabling ends the user's sessions. A key set to null (segment, phone) clears it.
     *
     * @param array{displayName?: string, userType?: 'customer'|'agent', disabled?: bool, segment?: string|null, phone?: string|null} $params
     * @return array<string, mixed>
     */
    public function update(string $username, array $params): array
    {
        return $this->http->request('PATCH', '/api/v1/users/' . self::seg($username), null, $params)['user'];
    }

    /** @return array<string, mixed> */
    public function disable(string $username): array
    {
        return $this->update($username, ['disabled' => true]);
    }

    /** @return array<string, mixed> */
    public function enable(string $username): array
    {
        return $this->update($username, ['disabled' => false]);
    }

    /**
     * End every session the user has open.
     *
     * @return array{ok: true}
     */
    public function signOut(string $username): array
    {
        return $this->http->request('POST', '/api/v1/users/' . self::seg($username) . '/sign-out');
    }

    /**
     * PDPL access request: everything held about the user (the platform's shape; it may grow).
     *
     * @return array<string, mixed>
     */
    public function export(string $username): array
    {
        return $this->http->request('GET', '/api/v1/users/' . self::seg($username) . '/export');
    }

    /**
     * PDPL erasure: deletes the account and its data (recordings on legal hold are kept). Irreversible.
     *
     * @return array{ok: true, alias: string, removed: array<string, int>, recordingsKeptOnLegalHold: list<string>}
     */
    public function delete(string $username, string $reason): array
    {
        return $this->http->request('DELETE', '/api/v1/users/' . self::seg($username), null, ['reason' => $reason]);
    }
}
