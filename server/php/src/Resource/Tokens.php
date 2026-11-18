<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Resource;

use Clarigoinfotech\Callio\Exception\ConflictException;
use Clarigoinfotech\Callio\HttpClient;

/** App tokens: short-lived JWTs your mobile app signs in with. */
final class Tokens extends Resource
{
    public function __construct(HttpClient $http, private readonly Users $users)
    {
        parent::__construct($http);
    }

    /**
     * A short-lived app token for an existing user (ttlSec 60–3600, default 900).
     *
     * @return array{token: string, userType: string, expiresAt: string}
     */
    public function create(string $username, ?int $ttlSec = null, ?string $deviceId = null): array
    {
        $body = ['username' => $username];
        if ($ttlSec !== null) {
            $body['ttlSec'] = $ttlSec;
        }
        if ($deviceId !== null) {
            $body['deviceId'] = $deviceId;   // the app's X-Device-Id: the token works on that device only
        }
        return $this->http->request('POST', '/api/v1/tokens', null, $body);
    }

    /**
     * The common job: make sure the app user exists, then issue their token. Creates the user if missing (a 409
     * means they already exist, which is fine). An existing user's display name and type are left as they are;
     * check `userType` on the result if it matters.
     *
     * @param array{displayName?: string, userType?: 'customer'|'agent', ttlSec?: int, phone?: string} $options
     * @return array{token: string, userType: string, expiresAt: string, created: bool}
     */
    public function forUser(string $username, array $options = []): array
    {
        $created = false;
        try {
            $this->users->create(['username' => $username] + array_filter(self::pick($options, ['displayName', 'userType', 'phone']), static fn ($v) => $v !== null));
            $created = true;
        } catch (ConflictException) {
            // already exists
        }
        $t = $this->create($username, isset($options['ttlSec']) ? (int) $options['ttlSec'] : null, isset($options['deviceId']) ? (string) $options['deviceId'] : null);
        return $t + ['created' => $created];
    }
}
