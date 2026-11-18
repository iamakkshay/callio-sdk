<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Tests;

use Clarigoinfotech\Callio\Callio;
use Clarigoinfotech\Callio\Exception\AuthenticationException;
use Clarigoinfotech\Callio\Exception\CallioException;
use Clarigoinfotech\Callio\Exception\ConflictException;
use Clarigoinfotech\Callio\Exception\ConnectionException;
use Clarigoinfotech\Callio\Exception\GoneException;
use Clarigoinfotech\Callio\Exception\NotFoundException;
use Clarigoinfotech\Callio\Exception\PermissionDeniedException;
use Clarigoinfotech\Callio\Exception\RateLimitException;
use Clarigoinfotech\Callio\Exception\RedirectException;
use Clarigoinfotech\Callio\Exception\ServerException;
use Clarigoinfotech\Callio\Exception\TimeoutException;
use Clarigoinfotech\Callio\Exception\ValidationException;
use Clarigoinfotech\Callio\Exception\WebhookVerificationException;
use Clarigoinfotech\Callio\HttpClient;
use Clarigoinfotech\Callio\Transport\Response;
use Clarigoinfotech\Callio\Transport\TransportException;
use Clarigoinfotech\Callio\Version;
use Clarigoinfotech\Callio\Webhook;
use PHPUnit\Framework\TestCase;

require_once __DIR__ . '/MockTransport.php';

/** Unit tests against a scripted transport: no network (except the CurlTransport tests on a loopback server). */
final class UnitTest extends TestCase
{
    private const KEY = 'cio_abc123_s3cret-value';

    private static function j(int $status, mixed $body, array $headers = []): Response
    {
        return MockTransport::json_($status, $body, $headers);
    }

    private static function client(MockTransport $m, int $maxRetries = 2): Callio
    {
        $c = new Callio(apiKey: self::KEY, baseUrl: 'https://api.example.test/', maxRetries: $maxRetries, transport: $m);
        $c->http->setSleep(static function (float $s): void {
        });
        return $c;
    }

    private static function assertThrowsClass(string $class, callable $fn): \Throwable
    {
        try {
            $fn();
        } catch (\Throwable $e) {
            self::assertSame($class, $e::class, $e->getMessage());
            return $e;
        }
        self::fail("expected {$class}");
    }

    public function testSendsBearerJsonAndUserAgent(): void
    {
        $m = new MockTransport(self::j(201, ['user' => ['username' => 'u1', 'extension' => '1001']]));
        $u = self::client($m)->users->create(['username' => 'u1', 'displayName' => 'U One', 'userType' => 'customer']);
        self::assertSame('1001', $u['extension']);
        $c = $m->calls[0];
        self::assertSame('https://api.example.test/api/v1/users', $c['url']);
        self::assertSame('POST', $c['method']);
        self::assertSame('Bearer ' . self::KEY, $c['headers']['Authorization']);
        self::assertSame('application/json', $c['headers']['Content-Type']);
        self::assertMatchesRegularExpression('#^callio-server-php/' . preg_quote(Version::VERSION) . ' php/#', $c['headers']['User-Agent']);
        self::assertSame(['username' => 'u1', 'displayName' => 'U One', 'userType' => 'customer'], $m->json(0));
    }

    public function testQueryAndPathEncoding(): void
    {
        $m = new MockTransport(self::j(200, ['users' => []]), self::j(200, ['events' => [], 'next' => 5]), self::j(200, ['user' => []]), self::j(200, ['recordings' => []]));
        $c = self::client($m);
        $c->users->list(['q' => 'sa ra', 'type' => 'agent', 'status' => null]);
        $c->events->list(['after' => 5, 'types' => ['call.', 'chat.']]);
        $c->users->get('a/b@c');
        $c->recordings->list(['from' => new \DateTimeImmutable('2026-01-01T00:00:00Z'), 'minDuration' => 10]);
        self::assertSame('https://api.example.test/api/v1/users?q=sa+ra&type=agent', $m->calls[0]['url']);
        self::assertSame('https://api.example.test/api/v1/events?after=5&types=call.%2Cchat.', $m->calls[1]['url']);
        self::assertSame('https://api.example.test/api/v1/users/a%2Fb%40c', $m->calls[2]['url']);
        self::assertSame('https://api.example.test/api/v1/recordings?from=2026-01-01T00%3A00%3A00.000Z&minDuration=10', $m->calls[3]['url']);
    }

    public function testStatusesMapToTypedExceptions(): void
    {
        $cases = [400 => ValidationException::class, 401 => AuthenticationException::class, 403 => PermissionDeniedException::class,
            404 => NotFoundException::class, 409 => ConflictException::class, 410 => GoneException::class, 500 => ServerException::class, 418 => CallioException::class];
        foreach ($cases as $status => $class) {
            $m = new MockTransport(self::j($status, ['error' => "reason {$status}"]));
            /** @var CallioException $e */
            $e = self::assertThrowsClass($class, fn () => self::client($m, 0)->orders->get('X'));
            self::assertSame($status, $e->getStatus());
            self::assertSame("reason {$status}", $e->getMessage());
            self::assertSame('GET /api/v1/orders/X', $e->getRequest());
            self::assertStringNotContainsString(self::KEY, (string) $e . $e->getTraceAsString());
        }
    }

    public function testIpAllowList403(): void
    {
        $m = new MockTransport(self::j(403, ['error' => "this network (203.0.113.9) is not allowed to use this organisation's API"]));
        $e = self::assertThrowsClass(PermissionDeniedException::class, fn () => self::client($m)->users->list());
        self::assertStringContainsString('not allowed', $e->getMessage());
    }

    public function testGetRetriesHonouringRetryAfter(): void
    {
        $m = new MockTransport(self::j(429, ['error' => 'slow down'], ['Retry-After' => '2']), self::j(503, ['error' => 'busy']), self::j(200, ['orders' => [['id' => 'A']]]));
        $c = self::client($m);
        $waits = [];
        $c->http->setBackoff(function (int $a, ?float $ra) use (&$waits): float {
            $waits[] = [$a, $ra];
            return 0.0;
        });
        self::assertSame('A', $c->orders->list()[0]['id']);
        self::assertCount(3, $m->calls);
        self::assertSame([[0, 2.0], [1, null]], $waits);
    }

    public function testGivesUpWithRateLimitRetryAfter(): void
    {
        $m = new MockTransport(self::j(429, ['error' => 'a'], ['Retry-After' => '7']), self::j(429, ['error' => 'b'], ['Retry-After' => '7']));
        /** @var RateLimitException $e */
        $e = self::assertThrowsClass(RateLimitException::class, fn () => self::client($m, 1)->cdr->list());
        self::assertSame(7.0, $e->getRetryAfter());
        self::assertSame(429, $e->getStatus());
        self::assertCount(2, $m->calls);
    }

    public function testPostAndPatchNeverRetried(): void
    {
        $m1 = new MockTransport(self::j(503, ['error' => 'busy']));
        self::assertThrowsClass(ServerException::class, fn () => self::client($m1)->orders->create(['id' => 'O1', 'customer' => 'c']));
        self::assertCount(1, $m1->calls);
        $m2 = new MockTransport(self::j(429, ['error' => 'slow'], ['Retry-After' => '1']));
        self::assertThrowsClass(RateLimitException::class, fn () => self::client($m2)->orders->close('O1'));
        self::assertCount(1, $m2->calls);
    }

    public function testNetworkErrorsRetriedForGet(): void
    {
        $boom = static fn () => throw new TransportException('connection refused');
        $m = new MockTransport($boom, $boom, $boom);
        /** @var ConnectionException $e */
        $e = self::assertThrowsClass(ConnectionException::class, fn () => self::client($m)->groups->list());
        self::assertSame(0, $e->getStatus());
        self::assertStringNotContainsString(self::KEY, (string) $e);
        self::assertNull($e->getPrevious());
        self::assertCount(3, $m->calls);
    }

    public function testTimeoutFromTransport(): void
    {
        $m = new MockTransport(static fn () => throw new TransportException('timed out', true));
        $e = self::assertThrowsClass(TimeoutException::class, fn () => self::client($m, 0)->users->get('x'));
        self::assertInstanceOf(ConnectionException::class, $e);
    }

    public function testForUserCreatesThenIssues(): void
    {
        $m = new MockTransport(self::j(201, ['user' => ['username' => 'c1']]), self::j(200, ['token' => 'jwt', 'userType' => 'customer', 'expiresAt' => 'later']));
        $t = self::client($m)->tokens->forUser('c1', ['displayName' => 'C', 'userType' => 'customer', 'ttlSec' => 600]);
        self::assertSame(['token' => 'jwt', 'userType' => 'customer', 'expiresAt' => 'later', 'created' => true], $t);
        self::assertSame(['username' => 'c1', 'displayName' => 'C', 'userType' => 'customer'], $m->json(0));
        self::assertSame(['username' => 'c1', 'ttlSec' => 600], $m->json(1));
    }

    public function testForUser409MeansExists(): void
    {
        $m = new MockTransport(self::j(409, ['error' => 'user exists']), self::j(200, ['token' => 'jwt', 'userType' => 'agent', 'expiresAt' => 'x']));
        $t = self::client($m)->tokens->forUser('a1', ['userType' => 'agent']);
        self::assertFalse($t['created']);
        self::assertSame('jwt', $t['token']);
    }

    public function testForUserPropagatesOtherErrors(): void
    {
        $m = new MockTransport(self::j(403, ['error' => 'seat quota reached']));
        self::assertThrowsClass(PermissionDeniedException::class, fn () => self::client($m)->tokens->forUser('a1'));
        self::assertCount(1, $m->calls);
    }

    public function testOrderHelpersPatch(): void
    {
        $o = ['order' => ['id' => 'O1']];
        $m = new MockTransport(self::j(200, $o), self::j(200, $o), self::j(200, $o), self::j(200, $o));
        $c = self::client($m);
        $c->orders->assign('O1', 'drv');
        $c->orders->assign('O1', null);
        $c->orders->close('O1');
        $c->orders->reopen('O1');
        $got = array_map(null, array_column($m->calls, 'method'), array_map(fn ($i) => $m->json($i), range(0, 3)));
        self::assertSame([['PATCH', ['agent' => 'drv']], ['PATCH', ['agent' => null]], ['PATCH', ['status' => 'closed']], ['PATCH', ['status' => 'active']]], $got);
    }

    public function testUsersDisableEnableAndNullableFields(): void
    {
        $u = ['user' => ['username' => 'u1']];
        $m = new MockTransport(self::j(200, $u), self::j(200, $u), self::j(200, $u));
        $c = self::client($m);
        $c->users->disable('u1');
        $c->users->enable('u1');
        $c->users->update('u1', ['displayName' => 'N', 'segment' => null]);
        self::assertSame(['disabled' => true], $m->json(0));
        self::assertSame(['disabled' => false], $m->json(1));
        self::assertSame(['displayName' => 'N', 'segment' => null], $m->json(2));
    }

    public function testUsersDeleteSendsReason(): void
    {
        $m = new MockTransport(self::j(200, ['ok' => true, 'alias' => 'erased-1', 'removed' => [], 'recordingsKeptOnLegalHold' => []]));
        $r = self::client($m)->users->delete('u1', 'customer asked');
        self::assertSame('erased-1', $r['alias']);
        self::assertSame('DELETE', $m->calls[0]['method']);
        self::assertSame(['reason' => 'customer asked'], $m->json(0));
    }

    public function testRecordingAudioStreamsAndDownloads(): void
    {
        $bytes = "OggS\x01\x02\x03";
        $audio = static fn () => new Response(200, ['Content-Type' => 'audio/ogg', 'Content-Length' => '7'], $bytes);
        $m = new MockTransport($audio, $audio, $audio);
        $c = self::client($m);
        $a = $c->recordings->audio('rec-1', 'QA review — طلب');
        self::assertSame('audio/ogg', $a->contentType);
        self::assertSame(7, $a->contentLength);
        self::assertSame($bytes, implode('', iterator_to_array($a->chunks(3), false)));
        $a->close();
        self::assertSame('QA review — طلب', $m->query(0, 'reason'));
        self::assertSame('*/*', $m->calls[0]['headers']['Accept']);
        self::assertTrue($m->calls[0]['stream']);
        $file = tempnam(sys_get_temp_dir(), 'callio-');
        self::assertSame(7, $c->recordings->download('rec-1', $file, 'dispute 123'));
        self::assertSame($bytes, file_get_contents($file));
        unlink($file);
        $mem = fopen('php://memory', 'w+b');
        self::assertSame(7, $c->recordings->download('rec-1', $mem, 'dispute 123'));
        rewind($mem);
        self::assertSame($bytes, stream_get_contents($mem));
    }

    public function testRecordingAudioRequiresReasonAndMaps410(): void
    {
        $m = new MockTransport(self::j(410, ['error' => 'this recording was deleted']));
        $c = self::client($m);
        self::assertThrowsClass(\InvalidArgumentException::class, fn () => $c->recordings->audio('r', 'no'));
        self::assertThrowsClass(\InvalidArgumentException::class, fn () => $c->recordings->transcript('r', '    '));
        self::assertThrowsClass(GoneException::class, fn () => $c->recordings->audio('r', 'audit check'));
        self::assertCount(1, $m->calls);
    }

    public function testRejectsDotPathSegments(): void
    {
        $m = new MockTransport();
        $c = self::client($m);
        foreach (['', '.', '..'] as $id) {
            self::assertThrowsClass(\InvalidArgumentException::class, fn () => $c->users->get($id));
            self::assertThrowsClass(\InvalidArgumentException::class, fn () => $c->orders->close($id));
            self::assertThrowsClass(\InvalidArgumentException::class, fn () => $c->groups->delete($id));
        }
        self::assertCount(0, $m->calls);
    }

    public function testTranscript(): void
    {
        $m = new MockTransport(self::j(200, ['transcript' => ['text' => 'hello', 'language' => 'en', 'segments' => [['start' => 0, 'end' => 1.5, 'text' => 'hello']]]]));
        $t = self::client($m)->recordings->transcript('r1', 'QA review');
        self::assertSame('hello', $t['text']);
        self::assertSame(1.5, $t['segments'][0]['end']);
        self::assertSame('QA review', $m->query(0, 'reason'));
    }

    public function testEventsIteratePagesUntilCaughtUp(): void
    {
        $m = new MockTransport(self::j(200, ['events' => [['id' => 1], ['id' => 2]], 'next' => 2]), self::j(200, ['events' => [['id' => 3]], 'next' => 3]), self::j(200, ['events' => [], 'next' => 3]));
        $ids = [];
        foreach (self::client($m)->events->iterate(['limit' => 2]) as $e) {
            $ids[] = $e['id'];
        }
        self::assertSame([1, 2, 3], $ids);
        self::assertSame(['0', '2', '3'], [$m->query(0, 'after'), $m->query(1, 'after'), $m->query(2, 'after')]);
    }

    public function testRawRequestEscapeHatch(): void
    {
        $m = new MockTransport(self::j(200, ['hello' => 'world']));
        self::assertSame(['hello' => 'world'], self::client($m)->http->request('GET', '/api/v1/whatever', ['x' => 1]));
        self::assertSame('https://api.example.test/api/v1/whatever?x=1', $m->calls[0]['url']);
    }

    public function testKeyNeverInDumpsJsonOrTraces(): void
    {
        $c = self::client(new MockTransport());
        ob_start();
        var_dump($c);
        var_dump($c->http);
        $dump = ob_get_clean();
        self::assertStringNotContainsString(self::KEY, $dump . print_r($c, true) . json_encode($c) . json_encode($c->http));
        self::assertThrowsClass(\LogicException::class, fn () => serialize($c));
        // A constructor error's trace does not carry the key (#[\SensitiveParameter], PHP 8.2+).
        try {
            new Callio(apiKey: self::KEY, baseUrl: 'ftp://x');
            self::fail('accepted ftp');
        } catch (CallioException $e) {
            if (PHP_VERSION_ID >= 80200) {
                self::assertStringNotContainsString(self::KEY, $e->getTraceAsString());
            }
        }
    }

    public function testConstructorValidatesReadsEnvAndRequiresHttps(): void
    {
        $saveK = getenv('CALLIO_API_KEY');
        $saveU = getenv('CALLIO_BASE_URL');
        putenv('CALLIO_API_KEY');
        putenv('CALLIO_BASE_URL');
        try {
            self::assertStringContainsString('apiKey is required', self::assertThrowsClass(CallioException::class, fn () => new Callio(baseUrl: 'https://x'))->getMessage());
            self::assertStringContainsString('baseUrl is required', self::assertThrowsClass(CallioException::class, fn () => new Callio(apiKey: self::KEY))->getMessage());
            self::assertStringContainsString('https', self::assertThrowsClass(CallioException::class, fn () => new Callio(apiKey: self::KEY, baseUrl: 'api.example.sa'))->getMessage());
            self::assertStringContainsString('allowInsecure', self::assertThrowsClass(CallioException::class, fn () => new Callio(apiKey: self::KEY, baseUrl: 'http://localhost:8080'))->getMessage());
            self::assertSame('http://localhost:8080', (new Callio(apiKey: self::KEY, baseUrl: 'http://localhost:8080/', allowInsecure: true))->http->baseUrl);
            putenv('CALLIO_API_KEY=' . self::KEY);
            putenv('CALLIO_BASE_URL=https://env.example/');
            self::assertSame('https://env.example', (new Callio())->http->baseUrl);
        } finally {
            putenv($saveK === false ? 'CALLIO_API_KEY' : "CALLIO_API_KEY={$saveK}");
            putenv($saveU === false ? 'CALLIO_BASE_URL' : "CALLIO_BASE_URL={$saveU}");
        }
    }

    public function testRedirectsAreRefused(): void
    {
        $m = new MockTransport(self::j(302, null, ['Location' => 'https://evil.example/steal?x=1']), self::j(200, ['users' => []]));
        /** @var RedirectException $e */
        $e = self::assertThrowsClass(RedirectException::class, fn () => self::client($m)->users->list());
        self::assertSame(302, $e->getStatus());
        self::assertStringContainsString('https://evil.example', $e->getMessage());
        self::assertCount(1, $m->calls);
    }

    public function testCurlTransportRefusesRedirectsTimesOutAndStreams(): void
    {
        $port = random_int(20000, 40000);
        $proc = proc_open([PHP_BINARY, '-S', "127.0.0.1:{$port}", __DIR__ . '/fixtures/router.php'], [1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes);
        try {
            $up = false;
            for ($i = 0; $i < 50 && !$up; $i++) {
                usleep(100_000);
                $s = @fsockopen('127.0.0.1', $port);
                if ($s) {
                    fclose($s);
                    $up = true;
                }
            }
            self::assertTrue($up, 'php -S did not start');
            $c = new Callio(apiKey: self::KEY, baseUrl: "http://127.0.0.1:{$port}", timeout: 1.0, maxRetries: 0, allowInsecure: true);
            self::assertThrowsClass(RedirectException::class, fn () => $c->users->list());
            $a = $c->recordings->audio('r1', 'QA review');
            self::assertSame('OggS-stream', stream_get_contents($a->stream()));
            $echo = $c->http->request('PATCH', '/echo', null, ['a' => 1]);
            self::assertSame(['auth' => 'Bearer ' . self::KEY, 'method' => 'PATCH', 'body' => '{"a":1}'], $echo);
            // Last: php -S is single-threaded and this handler sleeps.
            self::assertThrowsClass(TimeoutException::class, fn () => $c->groups->list());
        } finally {
            proc_terminate($proc);
            proc_close($proc);
        }
    }

    public function testParseRetryAfter(): void
    {
        self::assertSame(3.0, HttpClient::parseRetryAfter('3'));
        $s = HttpClient::parseRetryAfter(gmdate('D, d M Y H:i:s', time() + 5) . ' GMT');
        self::assertTrue($s >= 4 && $s <= 6, (string) $s);
        self::assertNull(HttpClient::parseRetryAfter(''));
        self::assertNull(HttpClient::parseRetryAfter('soon'));
        self::assertNull(HttpClient::parseRetryAfter('-1'));
    }

    // ------------------------------------------------------------- webhooks

    private const SECRET = 'whsec_test';
    private const BODY = '{"tenantId":"lab","type":"order.assigned","order":{"id":"O1","agent":"drv"},"by":"apikey:abc","at":"2026-01-01T00:00:00Z"}';
    private const BODY_V1 = '{"id":"evt_01","tenantId":"lab","type":"recording.ready","recordingId":"rec-9","durationSec":42,"at":"2026-01-01T00:00:00Z"}';

    /** @return array<string, string> */
    private static function v1Headers(string $body, int $ts, string $secret): array
    {
        return ['X-Callio-Timestamp' => (string) $ts, 'X-Callio-Signature' => Webhook::signV1($body, $ts, $secret), 'X-NGX-Signature' => Webhook::sign($body, $secret)];
    }

    /** @group legacy */
    public function testLegacyVerify(): void
    {
        $sig = 'sha256=' . hash_hmac('sha256', self::BODY, self::SECRET);
        self::assertSame($sig, Webhook::sign(self::BODY, self::SECRET));
        self::assertTrue(Webhook::verify(self::BODY, $sig, self::SECRET));
        self::assertTrue(Webhook::verify(self::BODY, [$sig], self::SECRET));
        self::assertTrue(Webhook::verify(self::BODY, '  sha256=' . strtoupper(substr($sig, 7)) . ' ', self::SECRET));
        self::assertFalse(Webhook::verify(self::BODY . ' ', $sig, self::SECRET));
        self::assertFalse(Webhook::verify(self::BODY, $sig, 'other'));
        foreach ([null, '', 'sha256=', 'sha256=zz', substr($sig, 7), 'sha1=' . substr($sig, 7), $sig . '00', []] as $h) {
            self::assertFalse(Webhook::verify(self::BODY, $h, self::SECRET), var_export($h, true));
        }
        self::assertThrowsClass(\InvalidArgumentException::class, fn () => Webhook::verify(self::BODY, $sig, ''));
    }

    public function testLegacyParse(): void
    {
        $ev = Webhook::parse(self::BODY, Webhook::sign(self::BODY, self::SECRET), self::SECRET);
        self::assertTrue($ev->isOrderEvent());
        self::assertSame('drv', $ev['order']['agent']);
        self::assertThrowsClass(WebhookVerificationException::class, fn () => Webhook::parse(self::BODY, 'sha256=' . str_repeat('0', 64), self::SECRET));
        $e = self::assertThrowsClass(WebhookVerificationException::class, fn () => Webhook::parse('nope', Webhook::sign('nope', self::SECRET), self::SECRET));
        self::assertSame(400, $e->getStatus());
    }

    public function testVerifyRequestV1(): void
    {
        $now = time();
        $h = self::v1Headers(self::BODY_V1, $now, self::SECRET);
        self::assertSame('v1=' . hash_hmac('sha256', $now . '.' . self::BODY_V1, self::SECRET), $h['X-Callio-Signature']);
        Webhook::verifyRequest(self::BODY_V1, $h, self::SECRET);
        $ev = Webhook::parseRequest(self::BODY_V1, $h, self::SECRET);
        self::assertSame('evt_01', $ev->id());
        self::assertTrue($ev->isRecordingReady());
        self::assertSame('rec-9', $ev['recordingId']);
        // Laravel/Symfony style (lower-case, list values) and $_SERVER style.
        $lower = [];
        $server = [];
        foreach ($h as $k => $v) {
            $lower[strtolower($k)] = [$v];
            $server['HTTP_' . strtoupper(str_replace('-', '_', $k))] = $v;
        }
        Webhook::verifyRequest(self::BODY_V1, $lower, self::SECRET);
        Webhook::verifyRequest(self::BODY_V1, $server, self::SECRET);
        // Rotation: any of several v1 signatures may match.
        $rot = $h;
        $rot['X-Callio-Signature'] = 'v1=' . str_repeat('0', 64) . ', ' . $h['X-Callio-Signature'];
        Webhook::verifyRequest(self::BODY_V1, $rot, self::SECRET);
        self::addToAssertionCount(4);
    }

    public function testVerifyRequestRejects(): void
    {
        $now = time();
        $swapped = self::v1Headers(self::BODY_V1, $now, self::SECRET);
        $swapped['X-Callio-Timestamp'] = (string) ($now + 1);
        $malformed = self::v1Headers(self::BODY_V1, $now, self::SECRET);
        $malformed['X-Callio-Timestamp'] = 'yesterday';
        $noV1 = self::v1Headers(self::BODY_V1, $now, self::SECRET);
        unset($noV1['X-Callio-Signature']);
        $legacyOnly = self::v1Headers(self::BODY_V1, $now, self::SECRET);
        unset($legacyOnly['X-Callio-Timestamp']);
        $bad = [
            'tampered' => [self::BODY_V1 . ' ', self::v1Headers(self::BODY_V1, $now, self::SECRET), []],
            'wrong secret' => [self::BODY_V1, self::v1Headers(self::BODY_V1, $now, 'other'), []],
            'stale (replay)' => [self::BODY_V1, self::v1Headers(self::BODY_V1, $now - 301, self::SECRET), []],
            'future' => [self::BODY_V1, self::v1Headers(self::BODY_V1, $now + 301, self::SECRET), []],
            'swapped timestamp' => [self::BODY_V1, $swapped, []],
            'malformed timestamp' => [self::BODY_V1, $malformed, []],
            'timestamp without v1' => [self::BODY_V1, $noV1, ['allowLegacy' => true]],
            'legacy only, not allowed' => [self::BODY_V1, $legacyOnly, []],
            'custom tolerance' => [self::BODY_V1, self::v1Headers(self::BODY_V1, $now - 60, self::SECRET), ['tolerance' => 30]],
            'clock' => [self::BODY_V1, self::v1Headers(self::BODY_V1, $now, self::SECRET), ['now' => $now + 1000]],
        ];
        foreach ($bad as $name => [$body, $h, $o]) {
            try {
                Webhook::verifyRequest($body, $h, self::SECRET, $o);
                self::fail("accepted: {$name}");
            } catch (WebhookVerificationException $e) {
                self::assertSame(401, $e->getStatus(), $name);
            }
            self::assertThrowsClass(WebhookVerificationException::class, fn () => Webhook::parseRequest($body, $h, self::SECRET, $o));
        }
        Webhook::verifyRequest(self::BODY_V1, self::v1Headers(self::BODY_V1, $now - 600, self::SECRET), self::SECRET, ['tolerance' => 900]);
        self::assertThrowsClass(\InvalidArgumentException::class, fn () => Webhook::verifyRequest(self::BODY_V1, self::v1Headers(self::BODY_V1, $now, self::SECRET), ''));
    }

    public function testVerifyRequestAllowLegacy(): void
    {
        Webhook::verifyRequest(self::BODY_V1, ['X-NGX-Signature' => Webhook::sign(self::BODY_V1, self::SECRET)], self::SECRET, ['allowLegacy' => true]);
        self::assertThrowsClass(WebhookVerificationException::class, fn () => Webhook::verifyRequest(self::BODY_V1, ['X-NGX-Signature' => Webhook::sign(self::BODY_V1, 'other')], self::SECRET, ['allowLegacy' => true]));
    }

    public function testVersionMatchesComposer(): void
    {
        self::assertSame(json_decode((string) file_get_contents(__DIR__ . '/../composer.json'), true)['version'], Version::VERSION);
    }
}
