<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Exception;

/** 403: the organisation is suspended, a seat quota is reached, the user is disabled, or the call came
 * from a network outside the organisation's API allow-list. */
class PermissionDeniedException extends CallioException
{
}
