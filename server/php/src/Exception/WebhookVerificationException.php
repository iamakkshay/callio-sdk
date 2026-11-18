<?php

declare(strict_types=1);

namespace Clarigoinfotech\Callio\Exception;

/** A bad or missing webhook signature or timestamp (status 401), or a body that is not a Callio event (400). */
class WebhookVerificationException extends CallioException
{
}
