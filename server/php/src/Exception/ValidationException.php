<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Exception;

/** 400: invalid input (bad id or username, unknown user, wrong user type, missing reason…). */
class ValidationException extends CallioException
{
}
