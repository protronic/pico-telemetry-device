# boot.py - Startet WLAN-Verbindung beim Booten
# Für Raspberry Pi Pico 2 W mit MicroPython

import sys
import machine
import network
import time

# Lib-Ordner zu sys.path hinzufuegen, damit MicroPython Module darin findet
if '/Lib' not in sys.path:
    sys.path.append('/Lib')

from micro_dotenv import load_dotenv, get_env

load_dotenv()  # Load environment variables from .env file

# ==== WLAN-Zugangsdaten ====
WIFI_SSID = get_env('WIFI_SSID')
WIFI_PASSWORD = get_env('WIFI_PASSWORD', '')  # Passwort optional, falls kein Passwort benötigt wird
MAX_RETRIES = 10  # Anzahl der Verbindungsversuche

def connect_wifi():
    wlan = network.WLAN(network.STA_IF)
    wlan.active(True)

    if not wlan.isconnected():
        print(f"Verbinde mit WLAN '{WIFI_SSID}' ...")
        wlan.connect(WIFI_SSID, WIFI_PASSWORD)

        retries = 0
        while not wlan.isconnected() and retries < MAX_RETRIES:
            retries += 1
            print(f"  Versuch {retries}/{MAX_RETRIES} ...")
            time.sleep(1)

    if wlan.isconnected():
        print("WLAN verbunden!")
        print("IP-Adresse:", wlan.ifconfig()[0])
    else:
        print("WLAN-Verbindung fehlgeschlagen.")
        # Optional: Neustart nach Fehlschlag
        machine.reset()

# WLAN verbinden
try:
    connect_wifi()
except KeyboardInterrupt:
    print("WLAN-Verbindungsversuch manuell unterbrochen.")
    if (get_env("DEPLOY_STATUS") == "development"):
        exit()
    else:
        machine.reset()
except Exception as e:
    print("Fehler bei WLAN-Setup:", e)
    machine.reset()


try:
    from thingsboard_sdk.tb_device_mqtt import TBDeviceMqttClient

    print("thingsboard-micropython-client-sdk package already installed.")
except ImportError:
    print("Installing thingsboard-micropython-client-sdk package...")
    import mip
    mip.install('github:thingsboard/thingsboard-micropython-client-sdk')
    from thingsboard_sdk.tb_device_mqtt import TBDeviceMqttClient
