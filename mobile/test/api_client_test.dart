import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cc_remote/data/api_client.dart';

void main() {
  test('adds bearer and json headers to authenticated requests', () async {
    late http.BaseRequest request;
    final client = RemoteApiClient(
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response('{}', 200);
      }),
    );

    await client.post(
      Uri.parse('https://example.test'),
      '/api/sessions/demo/title',
      token: 'secret',
      jsonBody: true,
      body: '{}',
    );

    expect(
      request.url.toString(),
      'https://example.test/api/sessions/demo/title',
    );
    expect(request.headers['authorization'], 'Bearer secret');
    expect(request.headers['content-type'], 'application/json');
    client.close();
  });

  test('does not add authorization to pairing requests', () async {
    late http.BaseRequest request;
    final client = RemoteApiClient(
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response('{}', 200);
      }),
    );

    await client.post(
      Uri.parse('https://example.test'),
      '/api/pair',
      jsonBody: true,
      body: '{}',
    );

    expect(request.headers.containsKey('authorization'), isFalse);
    expect(request.headers['content-type'], 'application/json');
    client.close();
  });

  test('preserves an origin base path when resolving api routes', () async {
    late http.BaseRequest request;
    final client = RemoteApiClient(
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response('{}', 200);
      }),
    );

    await client.get(
      Uri.parse('https://example.test/tunnel'),
      '/api/status',
    );

    expect(request.url.toString(), 'https://example.test/tunnel/api/status');
    client.close();
  });
}
