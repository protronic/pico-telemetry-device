# -*- coding: utf-8 -*-
"""
ThingsBoard CPython-Testclient
==============================
Testet die MQTT-Kommunikation mit ThingsBoard (ohne Pico-Hardware):
  - Verbindung per MQTT (Credentials aus src/.env)
  - Server-RPC:  uploadFile, reboot
  - Client-RPC:  getServerTime  → Antwort wird geloggt

Voraussetzungen (einmalig):
    pip install tb-mqtt-client python-dotenv
"""

import json
import os
import sys
import time
import datetime
import threading
from pathlib import Path

from dotenv import load_dotenv
from tb_device_mqtt import TBDeviceMqttClient

# ── .env laden (aus src/.env, relativ zu diesem Skript) ──────────────────────
env_path = Path(__file__).parent / '.env'
if not env_path.exists():
    sys.exit(f'[ERROR] .env nicht gefunden: {env_path}')
load_dotenv(env_path)

BROKER = os.getenv('MQTT_BROKER')
PORT   = int(os.getenv('MQTT_PORT', 1883))
TOKEN  = os.getenv('MQTT_ACCESS_TOKEN')

# ── Server-seitige RPCs (ThingsBoard → Client) ────────────────────────────────
def rpc_handler(request_id, body):
    method = body.get('method')
    params = body.get('params', {})
    if isinstance(params, str):
        try:
            params = json.loads(params)
        except (json.JSONDecodeError, ValueError):
            params = {}
    print(f'\n[RPC ←] id={request_id}  method={method}')
    print(f'        params={params}')

    if method == 'uploadFile':
        filename = params.get('filename', '')
        content  = params.get('content', '')
        if not filename:
            tb.send_rpc_reply(request_id, {'success': False, 'error': 'No filename'})
            return
        PROTECTED = {'testclient.py', '.env'}
        # if Path(filename).name in PROTECTED:
        #     print(f'[RPC ←] uploadFile: {filename!r} ist geschuetzt – wird ignoriert')
        #     tb.send_rpc_reply(request_id, {'success': True, 'skipped': True, 'reason': 'protected'})
        #     return
        try:
            target = Path(__file__).parent / filename
            if Path(filename).name in PROTECTED:
                target = Path(__file__).parent / f'_{filename}'
            target.write_text(content, encoding='utf-8')
            print(f'[RPC ←] uploadFile: {target} geschrieben ({len(content)} Bytes)')
            tb.send_rpc_reply(request_id, {'success': True, 'filename': filename})
        except Exception as e:
            tb.send_rpc_reply(request_id, {'success': False, 'error': str(e)})

    elif method == 'reboot':
        print('[RPC ←] reboot angefordert – simulierter Neustart (CPython, kein reset)')
        tb.send_rpc_reply(request_id, {'success': True})

    else:
        print(f'[RPC ←] Unbekannte Methode: {method!r}')
        tb.send_rpc_reply(request_id, {'success': False, 'error': f'Unknown method: {method}'})


# ── Client-seitiger RPC: getServerTime (Client → ThingsBoard) ────────────────
def get_server_time():
    done = threading.Event()

    def _callback(request_id, response, exception=None):
        if exception:
            print(f'[RPC →] getServerTime Fehler: {exception}')
        else:
            print(f'[RPC →] getServerTime Rohantwort: {response}')
            ts = response.get('ts') or response.get('serverTime') if response else None
            if ts:
                dt = datetime.datetime.utcfromtimestamp(int(ts) / 1000)
                print(f'[RPC →] Server-Zeit: {dt.isoformat()} UTC')
            else:
                print('[RPC →] getServerTime: kein "ts" in Antwort')
        done.set()

    print('[RPC →] Sende getServerTime ...')
    tb.send_rpc_call('getServerTime', {}, _callback)
    if not done.wait(timeout=10):
        print('[RPC →] getServerTime: Timeout (keine Antwort in 10 s)')


# ── Verbinden ─────────────────────────────────────────────────────────────────
print(f'Verbinde mit ThingsBoard: {BROKER}:{PORT}')
tb = TBDeviceMqttClient(BROKER, PORT, TOKEN)
tb.set_server_side_rpc_request_handler(rpc_handler)
tb.connect()
time.sleep(1)   # kurz warten bis Verbindung stabil

# Raw-MQTT-Logger: zeigt ALLE eingehenden Nachrichten (Debug)
# _original_on_message = tb._client.on_message
# def _debug_on_message(client, userdata, message):
#     print(f'[MQTT RAW ↓] topic={message.topic!r}  payload={message.payload!r}')
#     return _original_on_message(client, userdata, message)
# tb._client.on_message = _debug_on_message

print('Verbunden.\n')

# ── Testaktionen ──────────────────────────────────────────────────────────────
tb.send_attributes({
    'test_client':    True,
    'location':       os.getenv('DEPLOY_LOCATION', 'testclient'),
    'commit_hash':    os.getenv('DEPLOY_COMMIT_HASH', ''),
    'git_url':        os.getenv('DEPLOY_GIT_URL', ''),
    'wifi_ssid':      os.getenv('WIFI_SSID', ''),
    'version':        os.getenv('SOFTWARE_VERSION', 'unknown'),
})
print('[Attr] Client-Attribute gesendet')

get_server_time()

# ── Warten auf eingehende RPCs ────────────────────────────────────────────────
print('\nWarte auf Server-RPC (Ctrl+C zum Beenden)...')
try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    print('\nBeende...')
    tb.disconnect()
