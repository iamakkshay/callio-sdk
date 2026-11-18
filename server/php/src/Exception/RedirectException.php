<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Exception;

/** 3xx: the server answered with a redirect. The SDK never follows one (it would carry the API key to
 * another host); usually the base URL is wrong (http:// instead of https://, or a moved host). */
class RedirectException extends CallioException
{
}
