<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Resource;

/** The event feed (BI). An event: id, type, callId, from, to, fromType, toType, orderId, at, payload. */
final class Events extends Resource
{
    /**
     * One page of the event feed, in order. Pass the returned `next` as `after` for the following page.
     *
     * @param array{after?: int, limit?: int, types?: list<string>|string} $params
     * @return array{events: list<array<string, mixed>>, next: int}
     */
    public function list(array $params = []): array
    {
        return $this->http->request('GET', '/api/v1/events', self::pick($params, ['after', 'limit', 'types']));
    }

    /**
     * Every event after `after`, page by page, until the feed is caught up. Remember the last `id` to resume.
     *
     * @param array{after?: int, limit?: int, types?: list<string>|string} $params
     * @return \Generator<int, array<string, mixed>>
     */
    public function iterate(array $params = []): \Generator
    {
        $after = (int) ($params['after'] ?? 0);
        for (;;) {
            $page = $this->list(['after' => $after] + $params);
            foreach ($page['events'] as $e) {
                yield $e;
            }
            if (!$page['events'] || $page['next'] <= $after) {
                return;
            }
            $after = (int) $page['next'];
        }
    }
}
