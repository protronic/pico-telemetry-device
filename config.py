'''
config.py
secrets muss folgende Eintraege enthalten:
    'sensor_id': str, Identifikation des Sensors
    i2c_bus': int, gewaehlter I2C-Bus
    'scl_pin': int, genutzer Clock-Pin
    'sda_pin': int, genutzer Daten-Pin
    'per_dataacq': bool, Entscheidung über periodische Messzyklen oder einmalig bzw. bei Abfrage
    'interval': int, Messinterval [ms]
    'ssid': str, WLAN Name
    'pw': str, WLAN Passwort

fuer eine Verbindung zu einem HTTP-Server
    'server_url': str, HTTP-Adresse des Sensors    
fuer eine low-level TCP-Verbindung
    'server_ip': str, IPv4-Adresse des Servers
    'server_port': int, geoeffneter Port des Servers
'''
from wifi_pw import pw

secrets = {
    'server_ip': '192.168.2.109',
    'server_port': 12345,
    'sensor_id': 'Entwicklung',
    'i2c_bus': 0,
    'scl_pin': 21,
    'sda_pin': 20,
    'per_dataacq': True,
    'interval': 5000,
    'server_url': 'https://database3.protronic-gmbh.de/query?database=PicoTelemetry',
    'server_url': 'http://10.19.28.29:3021/',
    'use_wdt': True,
    }

network_config = {
    'ssid': 'IOT_WIFI',
    'pw': pw,    
}
    
    
