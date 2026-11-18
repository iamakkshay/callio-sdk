<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Transport;

/** The default transport on ext-curl. Redirects are never followed; only http(s) is allowed. */
final class CurlTransport implements TransportInterface
{
    /** @param array<int, mixed> $curlOptions extra CURLOPT_* settings (proxy, CA bundle…); redirects stay off */
    public function __construct(private readonly array $curlOptions = [])
    {
        if (!extension_loaded('curl')) {
            throw new \LogicException('Callio: ext-curl is required');
        }
    }

    public function send(string $method, string $url, #[\SensitiveParameter] array $headers, ?string $body, float $timeout, $sink = null): Response
    {
        $ch = curl_init();
        $status = 0;
        $respHeaders = [];
        $errorBody = '';
        $headersDone = false;
        $start = microtime(true);
        $headerLines = [];
        foreach ($headers as $k => $v) {
            $headerLines[] = $k . ': ' . $v;
        }
        $headerLines[] = 'Expect:';

        $opts = $this->curlOptions + [CURLOPT_CONNECTTIMEOUT_MS => (int) ceil($timeout * 1000)];
        $opts[CURLOPT_URL] = $url;
        $opts[CURLOPT_CUSTOMREQUEST] = $method;
        $opts[CURLOPT_HTTPHEADER] = $headerLines;
        $opts[CURLOPT_FOLLOWLOCATION] = false;
        $opts[CURLOPT_PROTOCOLS] = CURLPROTO_HTTP | CURLPROTO_HTTPS;
        $opts[CURLOPT_RETURNTRANSFER] = false;
        $opts[CURLOPT_HEADERFUNCTION] = static function ($ch, string $line) use (&$status, &$respHeaders, &$headersDone): int {
            $t = trim($line);
            if (preg_match('#^HTTP/\S+\s+(\d{3})#', $t, $m)) {
                $status = (int) $m[1];
                $respHeaders = [];
            } elseif ($t === '') {
                if ($status >= 200) {
                    $headersDone = true;
                }
            } elseif (str_contains($t, ':')) {
                [$k, $v] = explode(':', $t, 2);
                $respHeaders[strtolower(trim($k))][] = trim($v);
            }
            return strlen($line);
        };
        $opts[CURLOPT_WRITEFUNCTION] = static function ($ch, string $chunk) use (&$status, &$errorBody, $sink): int {
            if ($sink !== null && $status >= 200 && $status < 300) {
                $n = fwrite($sink, $chunk);
                return $n === false ? 0 : $n;
            }
            $errorBody .= $chunk;
            return strlen($chunk);
        };
        if ($body !== null) {
            $opts[CURLOPT_POSTFIELDS] = $body;
        } elseif ($method === 'HEAD') {
            $opts[CURLOPT_NOBODY] = true;
        }
        if ($sink === null) {
            $opts[CURLOPT_TIMEOUT_MS] = (int) ceil($timeout * 1000);
        } else {
            // A stream: the timeout covers getting the response headers; the body then flows at its own pace.
            $opts[CURLOPT_NOPROGRESS] = false;
            // CURLOPT_XFERINFOFUNCTION is PHP 8.2+; CURLOPT_PROGRESSFUNCTION has the same contract on 8.1.
            $opts[\defined('CURLOPT_XFERINFOFUNCTION') ? \constant('CURLOPT_XFERINFOFUNCTION') : CURLOPT_PROGRESSFUNCTION] = static function () use (&$headersDone, $start, $timeout): int {
                return (!$headersDone && microtime(true) - $start > $timeout) ? 1 : 0;
            };
        }
        curl_setopt_array($ch, $opts);
        $ok = curl_exec($ch);
        $errno = curl_errno($ch);
        $error = curl_error($ch);
        curl_close($ch);

        if ($ok === false || $errno !== 0) {
            $timedOut = $errno === CURLE_OPERATION_TIMEDOUT || ($errno === CURLE_ABORTED_BY_CALLBACK && !$headersDone);
            if ($errno === CURLE_WRITE_ERROR && $headersDone) {
                throw new TransportException('could not write the response body: ' . $error);
            }
            throw new TransportException($timedOut ? 'timed out' : ($error !== '' ? $error : 'curl error ' . $errno), $timedOut);
        }
        return new Response($status, $respHeaders, $errorBody);
    }
}
