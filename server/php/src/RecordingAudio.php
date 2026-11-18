<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio;

/** A fetched audio stream (stereo Ogg/Opus, caller left). Read it in chunks and close it. */
final class RecordingAudio
{
    /** @param resource $stream */
    public function __construct(private $stream, public readonly string $contentType, public readonly ?int $contentLength)
    {
    }

    /** @return resource a readable stream, positioned at the start */
    public function stream()
    {
        return $this->stream;
    }

    public function read(int $length = 65536): string
    {
        $s = fread($this->stream, $length);
        return $s === false ? '' : $s;
    }

    /** @return \Generator<int, string> */
    public function chunks(int $size = 65536): \Generator
    {
        while (!feof($this->stream)) {
            $s = fread($this->stream, $size);
            if ($s === false || $s === '') {
                return;
            }
            yield $s;
        }
    }

    public function close(): void
    {
        if (is_resource($this->stream)) {
            fclose($this->stream);
        }
    }

    public function __destruct()
    {
        $this->close();
    }
}
