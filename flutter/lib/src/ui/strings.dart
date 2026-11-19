/// User-facing text of the ready-made widgets. English by default; pass your own instance (for example an
/// Arabic one) to any widget's `strings` parameter. The widgets lay out with directional insets, so
/// right-to-left locales mirror correctly.
class CallioStrings {
  const CallioStrings({
    this.incomingCall = 'Incoming call',
    this.calling = 'Calling',
    this.ringing = 'Ringing',
    this.connecting = 'Connecting',
    this.onHold = 'On hold',
    this.reconnecting = 'Reconnecting',
    this.callEnded = 'Call ended',
    this.declined = 'Declined',
    this.missed = 'Missed',
    this.noAnswer = 'No answer',
    this.busy = 'Busy',
    this.unreachable = 'Unreachable',
    this.answer = 'Answer',
    this.decline = 'Decline',
    this.end = 'End',
    this.mute = 'Mute',
    this.unmute = 'Unmute',
    this.speaker = 'Speaker',
    this.earpiece = 'Phone',
    this.bluetooth = 'Bluetooth',
    this.hold = 'Hold',
    this.resume = 'Resume',
    this.keypad = 'Keypad',
    this.hideKeypad = 'Hide',
    this.chat = 'Chat',
    this.qualityGood = 'Good connection',
    this.qualityFair = 'Fair connection',
    this.qualityPoor = 'Poor connection',
    this.qualityUnknown = 'Measuring connection',
    this.messageHint = 'Message',
    this.send = 'Send',
    this.shareLocation = 'Share location',
    this.noMessages = 'No messages yet',
    this.sending = 'Sending',
    this.sent = 'Sent',
    this.delivered = 'Delivered',
    this.read = 'Read',
    this.failed = 'Not sent',
    this.queued = 'Will deliver when they\'re online',
    this.audioOutput = 'Audio output',
    this.call = 'Call',
  });

  final String incomingCall, calling, ringing, connecting, onHold, reconnecting, callEnded;
  final String declined, missed, noAnswer, busy, unreachable;
  final String answer, decline, end, mute, unmute, speaker, earpiece, bluetooth, hold, resume, keypad, hideKeypad, chat;
  final String qualityGood, qualityFair, qualityPoor, qualityUnknown;
  final String messageHint, send, shareLocation, noMessages, sending, sent, delivered, read, failed, queued, audioOutput, call;

  /// Text for a call's end reason as the SDK reports it (ended, declined, missed, no-answer, busy, unreachable).
  String endReason(String? reason) => switch (reason) {
        'declined' => declined,
        'missed' => missed,
        'no-answer' => noAnswer,
        'busy' => busy,
        'unreachable' => unreachable,
        _ => callEnded,
      };
}
