<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Resource;

use Clarigoinfotech\Callio\RecordingAudio;

/** Call recordings. Every audio or transcript fetch needs a reason, written to the recording's access trail. */
final class Recordings extends Resource
{
    /**
     * Search recordings. `from` / `to` are ISO dates or DateTimeInterface; `user` is either party's extension;
     * durations in seconds; `status`: stored (default) | deleted | all.
     *
     * @param array{from?: string|\DateTimeInterface, to?: string|\DateTimeInterface, user?: string, callId?: string, orderId?: string, minDuration?: int, maxDuration?: int, status?: string, limit?: int} $params
     * @return list<array<string, mixed>>
     */
    public function list(array $params = []): array
    {
        return $this->http->request('GET', '/api/v1/recordings', $params)['recordings'];
    }

    /** @return array<string, mixed> */
    public function get(string $id): array
    {
        return $this->http->request('GET', '/api/v1/recordings/' . self::seg($id))['recording'];
    }

    /**
     * Fetch the audio as a stream. It is spooled to a php://temp stream (kept in memory up to 2 MB, then on
     * disk), never into a PHP string. For a file, prefer download().
     */
    public function audio(string $id, string $reason): RecordingAudio
    {
        $tmp = fopen('php://temp/maxmemory:2097152', 'w+b');
        if ($tmp === false) {
            throw new \RuntimeException('Callio: could not open a temporary stream');
        }
        try {
            $res = $this->stream($id, $reason, $tmp);
        } catch (\Throwable $e) {
            fclose($tmp);
            throw $e;
        }
        rewind($tmp);
        return new RecordingAudio($tmp, $res->header('Content-Type') ?: 'audio/ogg', $res->header('Content-Length') !== null ? (int) $res->header('Content-Length') : null);
    }

    /**
     * Stream the audio straight to a file path or a writable stream; returns the number of bytes written.
     *
     * @param string|resource $dest
     */
    public function download(string $id, $dest, string $reason): int
    {
        if (is_resource($dest)) {
            $start = ftell($dest);
            $this->stream($id, $reason, $dest);
            return $start === false ? (int) fstat($dest)['size'] : ftell($dest) - $start;
        }
        $f = fopen($dest, 'wb');
        if ($f === false) {
            throw new \RuntimeException("Callio: could not open {$dest} for writing");
        }
        try {
            $this->stream($id, $reason, $f);
            $n = ftell($f);
        } catch (\Throwable $e) {
            fclose($f);
            @unlink($dest);
            throw $e;
        }
        fclose($f);
        return (int) $n;
    }

    /**
     * The transcript; same rules as the audio. NotFoundException while it is still being transcribed.
     *
     * @return array{text: string, language?: string|null, segments?: list<array{start: float, end: float, text: string}>}
     */
    public function transcript(string $id, string $reason): array
    {
        return $this->http->request('GET', '/api/v1/recordings/' . self::seg($id) . '/transcript', ['reason' => self::reason($reason)])['transcript'];
    }

    /** @param resource $sink */
    private function stream(string $id, string $reason, $sink): \Clarigoinfotech\Callio\Transport\Response
    {
        $path = '/api/v1/recordings/' . self::seg($id) . '/audio';
        return $this->http->requestStream('GET', $path, ['reason' => self::reason($reason)], $sink);
    }
}
