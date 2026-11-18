<?php
// Loopback server for the CurlTransport tests (php -S 127.0.0.1:PORT tests/fixtures/router.php).
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if ($path === '/api/v1/users') {
    header('Location: http://127.0.0.1:1/evil', true, 307);
    return;
}
if ($path === '/api/v1/groups') {
    sleep(3);
    echo '{"groups":[]}';
    return;
}
if ($path === '/api/v1/recordings/r1/audio') {
    header('Content-Type: audio/ogg');
    echo 'OggS-stream';
    return;
}
if ($path === '/echo') {
    header('Content-Type: application/json');
    echo json_encode(['auth' => $_SERVER['HTTP_AUTHORIZATION'] ?? null, 'method' => $_SERVER['REQUEST_METHOD'], 'body' => file_get_contents('php://input')]);
    return;
}
http_response_code(404);
echo '{"error":"no such route"}';
