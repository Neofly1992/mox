#!/usr/bin/env python3
"""M4 loopback acceptance probe. Requires openai==3.19.2 and anthropic==1.8.0.

Run while Mox.app has the API enabled:
  python scripts/verify-m4-sdk.py --app .build/m4/Release/Mox.app --model '<installed Qwen3 alias>'
The key is fetched through the local management connection and never printed.
"""
import argparse
import json
import socket
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

from openai import OpenAI
from anthropic import Anthropic


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--data-root', type=Path,
                        default=Path.home() / 'Library/Application Support/Mox')
    parser.add_argument('--model')
    args = parser.parse_args()
    worker = args.app.resolve() / 'Contents/Helpers/MoxWorker.app/Contents/MacOS/mox'
    if not worker.is_file():
        parser.error('App does not contain a Mox worker')

    def command(*parts):
        return subprocess.check_output(
            [str(worker), *parts, '--data-root', str(args.data_root)], text=True).strip()

    status = command('api', 'status').split(' ', 1)
    if status[0] != 'running':
        parser.error('Enable the public API in Mox.app first')
    endpoint = status[1]
    key = command('api', 'key')
    discovery = json.loads((args.data_root / 'run/discovery.json').read_text())
    management_endpoint = discovery['privateEndpoint']
    management_token = discovery['token']
    rows = command('models', 'list').splitlines()
    model = args.model or next((row.split('  ')[1] for row in rows
        if 'mox:' in row and 'mlx-community/Qwen3-0.6B-4bit#' in row), None)
    if model is None:
        parser.error('Install the pinned Qwen3-0.6B-4bit managed artifact or pass --model')

    def expect_http(expected, base, path, *, method='GET', headers=None, body=None):
        request = urllib.request.Request(base + path, method=method, headers=headers or {},
            data=json.dumps(body).encode() if body is not None else None)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                actual, payload = response.status, response.read()
        except urllib.error.HTTPError as error:
            actual, payload = error.code, error.read()
        assert actual == expected, f'{path}: expected HTTP {expected}, received {actual}'
        if actual >= 400:
            parsed = json.loads(payload)
            assert isinstance(parsed.get('error'), dict), f'{path}: missing protocol error'

    def expect_rejected_socket_closed(expected, headers, body_chunks=()):
        address = urlsplit(endpoint)
        assert address.hostname == '127.0.0.1'
        request = ('POST /v1/chat/completions HTTP/1.1\r\n'
                   f'Host: 127.0.0.1:{address.port}\r\n'
                   + ''.join(f'{name}: {value}\r\n' for name, value in headers.items())
                   + '\r\n').encode()
        with socket.create_connection((address.hostname, address.port), timeout=5) as connection:
            connection.settimeout(5)
            connection.sendall(request)
            for chunk in body_chunks:
                try:
                    connection.sendall(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    break
            response = bytearray()
            while True:
                try:
                    part = connection.recv(65536)
                except ConnectionResetError:
                    break
                if not part:
                    break
                response.extend(part)
        status_line = response.split(b'\r\n', 1)[0]
        assert status_line.startswith(f'HTTP/1.1 {expected} '.encode()), status_line
        assert b'connection: close' in response.split(b'\r\n\r\n', 1)[0].lower()

    def expect_incomplete_body_deadline():
        address = urlsplit(endpoint)
        with socket.create_connection((address.hostname, address.port), timeout=5) as connection:
            connection.settimeout(20)
            connection.sendall(('POST /v1/chat/completions HTTP/1.1\r\n'
                f'Host: 127.0.0.1:{address.port}\r\n'
                f'Authorization: Bearer {key}\r\n'
                'Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n').encode())
            began = time.monotonic()
            while True:
                try:
                    if not connection.recv(65536):
                        break
                except ConnectionResetError:
                    break
            assert time.monotonic() - began < 20, 'incomplete request body held a connection'

    public = {'Authorization': 'Bearer ' + key}
    expect_http(200, endpoint, '/v1/models', headers=public)
    expect_http(401, endpoint, '/v1/models')
    expect_http(401, endpoint, '/v1/models',
        headers={'Authorization': 'Bearer ' + management_token})
    expect_http(401, management_endpoint, '/mox/v1/status', headers=public)
    expect_http(403, endpoint, '/v1/models',
        headers={**public, 'Origin': 'https://example.invalid'})
    base_request = {'model': model, 'messages': [{'role': 'user', 'content': 'Hello'}],
                    'max_tokens': 8}
    expect_http(400, endpoint, '/v1/chat/completions', method='POST',
        headers={**public, 'Content-Type': 'application/json'},
        body={**base_request, 'unsupported_field': True})
    expect_http(400, endpoint, '/v1/chat/completions', method='POST',
        headers={**public, 'Content-Type': 'application/json'},
        body={**base_request, 'tool_choice': 'required'})
    expect_http(404, endpoint, '/v1/chat/completions', method='POST',
        headers={**public, 'Content-Type': 'application/json'},
        body={**base_request, 'model': 'mox-missing-model'})
    expect_http(400, endpoint, '/v1/messages', method='POST',
        headers={'x-api-key': key, 'Content-Type': 'application/json',
                 'anthropic-version': '2099-01-01'},
        body={'model': model, 'max_tokens': 8,
              'messages': [{'role': 'user', 'content': 'Hello'}]})
    illegal_history = [{'role': 'user', 'content': 'lookup'},
        {'role': 'assistant', 'tool_calls': [{'id': 'call_1', 'type': 'function',
            'function': {'name': 'lookup_code', 'arguments': '{}'}}]},
        {'role': 'user', 'content': 'unrelated intervening turn'},
        {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'blue'}]
    expect_http(400, endpoint, '/v1/chat/completions', method='POST',
        headers={**public, 'Content-Type': 'application/json'},
        body={**base_request, 'messages': illegal_history})
    expect_rejected_socket_closed(403,
        {'Origin': 'https://example.invalid', 'Transfer-Encoding': 'chunked'})
    expect_rejected_socket_closed(401, {'Transfer-Encoding': 'chunked'})
    expect_rejected_socket_closed(413, {**public, 'Content-Type': 'application/json',
        'Content-Length': '16777217'})
    one_megabyte = b'x' * (1024 * 1024)
    chunks = [b'100000\r\n' + one_megabyte + b'\r\n' for _ in range(16)]
    chunks.append(b'1\r\nx\r\n')
    expect_rejected_socket_closed(413, {**public, 'Content-Type': 'application/json',
        'Transfer-Encoding': 'chunked'}, chunks)
    expect_incomplete_body_deadline()
    expect_http(200, endpoint, '/v1/models', headers=public)
    print('PASS live HTTP isolation and rejection paths: credentials, Origin, fields, model, version')
    print('PASS rejected bodies close sockets; incomplete body deadline; invalid tool history rejected')

    openai = OpenAI(api_key=key, base_url=endpoint + '/v1', timeout=120)
    anthropic = Anthropic(api_key=key, base_url=endpoint, timeout=120)
    prompt = 'Reply with the word blue.'
    text = openai.chat.completions.create(model=model, messages=[{'role': 'user', 'content': prompt}], max_tokens=80)
    assert text.usage and text.usage.prompt_tokens > 0 and text.usage.completion_tokens > 0
    chunks = list(openai.chat.completions.create(model=model,
        messages=[{'role': 'user', 'content': prompt}], max_tokens=80, stream=True,
        stream_options={'include_usage': True}))
    assert chunks[-1].usage and chunks[-1].usage.prompt_tokens > 0
    text = anthropic.messages.create(model=model, max_tokens=80,
        messages=[{'role': 'user', 'content': prompt}])
    assert text.usage.input_tokens > 0 and text.usage.output_tokens > 0
    with anthropic.messages.stream(model=model, max_tokens=80,
            messages=[{'role': 'user', 'content': prompt}]) as stream:
        assert stream.get_final_message().usage.input_tokens > 0
    print('PASS text and streaming: OpenAI Chat Completions, Anthropic Messages')

    schema = {'type': 'object', 'properties': {'code': {'type': 'string', 'enum': ['MOX-7']}},
              'required': ['code']}
    question = 'Use lookup_code with code MOX-7, then report its value.'
    tools = [{'type': 'function', 'function': {'name': 'lookup_code',
              'description': 'Look up a code in a fixed dictionary', 'parameters': schema}}]
    messages = [{'role': 'user', 'content': question}]
    first = openai.chat.completions.create(model=model, messages=messages, tools=tools,
        tool_choice='auto', max_tokens=300, temperature=0)
    calls = first.choices[0].message.tool_calls
    assert calls and calls[0].function.name == 'lookup_code'
    assert json.loads(calls[0].function.arguments) == {'code': 'MOX-7'}
    streamed_calls = {}
    for chunk in openai.chat.completions.create(model=model,
            messages=[{'role': 'user', 'content': question}], tools=tools,
            tool_choice='auto', max_tokens=300, temperature=0, stream=True):
        if not chunk.choices:
            continue
        for part in chunk.choices[0].delta.tool_calls or []:
            item = streamed_calls.setdefault(part.index, {'id': '', 'name': '', 'arguments': ''})
            item['id'] += part.id or ''
            if part.function:
                item['name'] += part.function.name or ''
                item['arguments'] += part.function.arguments or ''
    assert len(streamed_calls) == 1
    assert streamed_calls[0]['id'] and streamed_calls[0]['name'] == 'lookup_code'
    assert json.loads(streamed_calls[0]['arguments']) == {'code': 'MOX-7'}
    result = {'MOX-7': 'blue'}.get('MOX-7', 'unknown code')
    messages += [first.choices[0].message.model_dump(exclude_none=True),
                 {'role': 'tool', 'tool_call_id': calls[0].id, 'content': result}]
    final = openai.chat.completions.create(model=model, messages=messages, tools=tools,
        tool_choice='none', max_tokens=300, temperature=0)
    assert 'blue' in (final.choices[0].message.content or '').lower()

    tools = [{'name': 'lookup_code', 'description': 'Look up a code in a fixed dictionary',
              'input_schema': schema}]
    messages = [{'role': 'user', 'content': question}]
    first = anthropic.messages.create(model=model, max_tokens=300, messages=messages,
        tools=tools, tool_choice={'type': 'auto'})
    calls = [block for block in first.content if block.type == 'tool_use']
    assert calls and calls[0].name == 'lookup_code' and calls[0].input == {'code': 'MOX-7'}
    streamed_calls = {}
    for event in anthropic.messages.create(model=model, max_tokens=300,
            messages=[{'role': 'user', 'content': question}], tools=tools,
            tool_choice={'type': 'auto'}, stream=True):
        if event.type == 'content_block_start' and event.content_block.type == 'tool_use':
            streamed_calls[event.index] = {'id': event.content_block.id,
                                            'name': event.content_block.name, 'arguments': ''}
        if event.type == 'content_block_delta' and event.delta.type == 'input_json_delta':
            streamed_calls[event.index]['arguments'] += event.delta.partial_json
    assert len(streamed_calls) == 1
    streamed_call = next(iter(streamed_calls.values()))
    assert streamed_call['id'] and streamed_call['name'] == 'lookup_code'
    assert json.loads(streamed_call['arguments']) == {'code': 'MOX-7'}
    messages += [{'role': 'assistant', 'content': [block.model_dump(exclude_none=True)
                  for block in first.content]},
                 {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': calls[0].id,
                  'content': result}]}]
    final = anthropic.messages.create(model=model, max_tokens=300, messages=messages,
        tools=tools, tool_choice={'type': 'none'})
    assert 'blue' in ''.join(getattr(block, 'text', '') for block in final.content).lower()
    error_messages = messages[:-1] + [{'role': 'user', 'content': [
        {'type': 'tool_result', 'tool_use_id': calls[0].id,
         'content': 'unknown code', 'is_error': True}]}]
    recovered = anthropic.messages.create(model=model, max_tokens=120,
        messages=error_messages, tools=tools, tool_choice={'type': 'none'})
    assert recovered.stop_reason in ('end_turn', 'max_tokens')
    assert any(getattr(block, 'text', '').strip() for block in recovered.content)
    print('PASS client-executed lookup_code roundtrip and streamed tool arguments: both SDKs')
    print('PASS Anthropic error tool_result continuation')


if __name__ == '__main__':
    main()
