<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Tests;

use Clarigoinfotech\Callio\Callio;
use Clarigoinfotech\Callio\Exception\AuthenticationException;
use Clarigoinfotech\Callio\Exception\CallioException;
use Clarigoinfotech\Callio\Exception\ConflictException;
use Clarigoinfotech\Callio\Exception\NotFoundException;
use Clarigoinfotech\Callio\Exception\ValidationException;
use PHPUnit\Framework\Attributes\Depends;
use PHPUnit\Framework\TestCase;

/**
 * Integration test against a running Callio stack. It signs in to the admin API, creates a temporary API key
 * for the tenant, exercises the SDK, and cleans up everything it made (users, order, group, the key). Nothing
 * secret lives in this file; pass it in the environment:
 *
 *     CALLIO_ADMIN_PASS=… [CALLIO_ADMIN_USER=admin] [CALLIO_URL=http://localhost:8080] [CALLIO_TENANT=lab] \
 *       vendor/bin/phpunit --testsuite integration
 *
 * CALLIO_IT_AUDIO=1 also downloads one recording (that read is written to the recording's access trail).
 * Skipped when CALLIO_ADMIN_PASS is not set.
 */
final class IntegrationTest extends TestCase
{
    private static string $url;
    private static string $tenant;
    private static string $run;
    private static ?string $admin = null;
    /** @var array<string, mixed>|null */
    private static ?array $key = null;
    private static ?Callio $callio = null;
    /** @var list<string> */
    private static array $users = [];
    private static bool $groupMade = false;
    private static bool $orderMade = false;

    private static function env(string $k, string $d): string
    {
        $v = getenv($k);
        return $v === false || $v === '' ? $d : $v;
    }

    private static function cust(): string { return 'sdk-it-php-c-' . self::$run; }
    private static function agent(): string { return 'sdk-it-php-a-' . self::$run; }
    private static function order(): string { return 'SDK-IT-PHP-' . self::$run; }
    private static function group(): string { return 'sdk-it-php-g-' . self::$run; }

    /** @return array<string, mixed> */
    private static function adminReq(string $method, string $path, ?array $body = null): array
    {
        $ch = curl_init(self::$url . $path);
        $h = ['Content-Type: application/json'];
        if (self::$admin) {
            $h[] = 'Authorization: Bearer ' . self::$admin;
        }
        curl_setopt_array($ch, [CURLOPT_CUSTOMREQUEST => $method, CURLOPT_HTTPHEADER => $h, CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 15]
            + ($body !== null ? [CURLOPT_POSTFIELDS => json_encode($body)] : []));
        $raw = (string) curl_exec($ch);
        $st = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);
        $j = json_decode($raw, true) ?: [];
        if ($st >= 300 || $st === 0) {
            throw new \RuntimeException("{$method} {$path} → {$st} " . ($j['error'] ?? ''));
        }
        return $j;
    }

    public static function setUpBeforeClass(): void
    {
        $pass = getenv('CALLIO_ADMIN_PASS');
        if ($pass === false || $pass === '') {
            return;
        }
        self::$url = rtrim(self::env('CALLIO_URL', 'http://localhost:8080'), '/');
        self::$tenant = self::env('CALLIO_TENANT', 'lab');
        self::$run = base_convert((string) (int) (microtime(true) * 1000), 10, 36);
        self::$admin = self::adminReq('POST', '/api/admin/login', ['username' => self::env('CALLIO_ADMIN_USER', 'admin'), 'password' => $pass])['token'] ?? null;
        if (!self::$admin) {
            throw new \RuntimeException('admin login (MFA-enabled admins are not supported by this test)');
        }
        self::$key = self::adminReq('POST', '/api/admin/tenants/' . self::$tenant . '/api-keys', ['name' => 'sdk-it-php-' . self::$run])['key'];
        self::$callio = new Callio(apiKey: self::$key['key'], baseUrl: self::$url, userAgent: 'callio-it', allowInsecure: str_starts_with(self::$url, 'http://'));
    }

    public static function tearDownAfterClass(): void
    {
        $c = self::$callio;
        if (!$c) {
            return;
        }
        $quiet = static function (callable $f): void {
            try {
                $f();
            } catch (\Throwable) {
            }
        };
        try {
            if (self::$groupMade) {
                $quiet(fn () => $c->groups->delete(self::group()));
            }
            if (self::$orderMade) {
                $quiet(fn () => $c->orders->close(self::order())); // orders can't be deleted; erasing the users pseudonymises it
            }
            foreach (self::$users as $u) {
                $quiet(fn () => $c->users->delete($u, 'SDK integration test cleanup'));
            }
        } finally {
            self::adminReq('DELETE', '/api/admin/tenants/' . self::$tenant . '/api-keys/' . self::$key['id']);
        }
        try {
            $c->users->list(['limit' => 1]);
            throw new \RuntimeException('the revoked key still works');
        } catch (AuthenticationException) {
            // expected
        }
    }

    protected function setUp(): void
    {
        if (!self::$callio) {
            self::markTestSkipped('set CALLIO_ADMIN_PASS (and optionally CALLIO_ADMIN_USER, CALLIO_URL, CALLIO_TENANT)');
        }
    }

    private static function throws(string $class, callable $f): CallioException
    {
        try {
            $f();
        } catch (CallioException $e) {
            self::assertInstanceOf($class, $e, $e->getMessage());
            return $e;
        }
        self::fail("expected {$class}");
    }

    public function testUsers(): void
    {
        $c = self::$callio;
        $u = $c->users->create(['username' => self::cust(), 'displayName' => 'SDK IT Customer', 'userType' => 'customer']);
        self::$users[] = self::cust();
        self::assertSame(self::cust(), $u['username']);
        self::assertSame('customer', $u['userType']);
        self::assertNotEmpty($u['extension']);
        self::assertNotEmpty($u['initialPassword'] ?? null, 'a random password is returned once');
        self::throws(ConflictException::class, fn () => $c->users->create(['username' => self::cust()]));
        self::throws(ValidationException::class, fn () => $c->users->create(['username' => 'bad name!']));
        self::throws(NotFoundException::class, fn () => $c->users->get(self::cust() . '-missing'));

        self::assertSame('SDK IT Customer', $c->users->get(self::cust())['displayName']);
        $u = $c->users->update(self::cust(), ['displayName' => 'SDK IT Renamed', 'segment' => 'sdk-it']);
        self::assertSame('SDK IT Renamed', $u['displayName']);
        self::assertSame('sdk-it', $u['segment']);
        self::assertContains(self::cust(), array_column($c->users->list(['q' => self::cust()]), 'username'));

        $t = $c->tokens->create(self::cust(), 120);
        self::assertCount(3, explode('.', $t['token']));
        self::assertSame('customer', $t['userType']);
        self::assertGreaterThan(time(), strtotime($t['expiresAt']));
        self::assertSame(['ok' => true], $c->users->signOut(self::cust()));
        self::assertNotEmpty($c->users->export(self::cust())['exportedAt']);
    }

    #[Depends('testUsers')]
    public function testForUser(): void
    {
        $c = self::$callio;
        $first = $c->tokens->forUser(self::agent(), ['displayName' => 'SDK IT Agent', 'userType' => 'agent', 'ttlSec' => 60]);
        self::$users[] = self::agent();
        self::assertTrue($first['created']);
        self::assertSame('agent', $first['userType']);
        $again = $c->tokens->forUser(self::agent(), ['userType' => 'agent']);
        self::assertFalse($again['created']);
        self::assertNotEmpty($again['token']);
        $c->users->disable(self::agent());
        self::assertSame(403, self::throws(CallioException::class, fn () => $c->tokens->create(self::agent()))->getStatus());
        $c->users->enable(self::agent());
    }

    #[Depends('testForUser')]
    public function testOrdersAndEvents(): void
    {
        $c = self::$callio;
        $order = self::order();
        $before = $c->events->list(['after' => 0, 'limit' => 1])['next'];
        self::throws(ValidationException::class, fn () => $c->orders->create(['id' => $order, 'customer' => self::agent()])); // wrong user type
        $o = $c->orders->create(['id' => $order, 'customer' => self::cust(), 'label' => 'SDK integration test']);
        self::$orderMade = true;
        self::assertSame('active', $o['status']);
        self::assertNull($o['agent']);
        self::throws(ConflictException::class, fn () => $c->orders->create(['id' => $order, 'customer' => self::cust()]));
        self::assertSame('SDK integration test', $c->orders->get($order)['label']);
        self::assertContains($order, array_column($c->orders->list(['user' => self::cust()]), 'id'));
        self::assertSame(self::agent(), $c->orders->assign($order, self::agent())['agent']);
        self::assertSame('closed', $c->orders->close($order)['status']);
        self::assertSame('active', $c->orders->reopen($order)['status']);
        self::assertSame('closed', $c->orders->update($order, ['status' => 'closed'])['status']);
        self::throws(NotFoundException::class, fn () => $c->orders->get($order . '-nope'));

        $seen = [];
        foreach ($c->events->iterate(['after' => max(0, $before - 1), 'types' => ['order.'], 'limit' => 100]) as $e) {
            if (($e['orderId'] ?? null) === $order) {
                $seen[] = $e['type'];
            }
        }
        foreach (['order.created', 'order.assigned', 'order.closed', 'order.reopened'] as $t) {
            self::assertContains($t, $seen);
        }
    }

    #[Depends('testForUser')]
    public function testGroups(): void
    {
        $c = self::$callio;
        $g = $c->groups->create(['id' => self::group(), 'name' => 'SDK IT group', 'members' => [self::cust(), self::agent()]]);
        self::$groupMade = true;
        self::assertCount(2, $g['members']);
        self::assertSame('SDK IT group', $c->groups->get(self::group())['name']);
        $u = $c->groups->update(self::group(), ['name' => 'SDK IT renamed', 'remove' => [self::agent()]]);
        self::assertSame('SDK IT renamed', $u['name']);
        self::assertSame([self::cust()], array_column($u['members'], 'username'));
        self::assertContains(self::group(), array_column($c->groups->list(), 'id'));
        self::assertSame(['ok' => true], $c->groups->delete(self::group()));
        self::$groupMade = false;
        self::throws(NotFoundException::class, fn () => $c->groups->get(self::group()));
    }

    public function testRecordingsAndCdr(): void
    {
        $c = self::$callio;
        $recs = $c->recordings->list(['limit' => 5]);
        self::assertIsArray($recs);
        if ($recs) {
            self::assertSame($recs[0]['id'], $c->recordings->get($recs[0]['id'])['id']);
            if (getenv('CALLIO_IT_AUDIO') === '1') {
                $mem = fopen('php://temp', 'w+b');
                self::assertSame($recs[0]['bytes'], $c->recordings->download($recs[0]['id'], $mem, 'SDK integration test'));
                rewind($mem);
                self::assertSame('OggS', fread($mem, 4));
            }
        }
        self::throws(NotFoundException::class, fn () => $c->recordings->get('no-such-recording'));
        self::throws(NotFoundException::class, fn () => $c->recordings->audio('no-such-recording', 'SDK integration test'));
        $cdr = $c->cdr->list(['days' => 30]);
        self::assertSame(30, $cdr['days']);
        self::assertIsArray($cdr['calls']);
    }

    #[Depends('testGroups')]
    public function testErasure(): void
    {
        $c = self::$callio;
        $r = $c->users->delete(self::agent(), 'SDK integration test cleanup');
        self::assertTrue($r['ok']);
        self::assertStringStartsWith('erased-', $r['alias']);
        self::$users = array_values(array_diff(self::$users, [self::agent()]));
        self::throws(NotFoundException::class, fn () => $c->users->get(self::agent()));
    }
}
