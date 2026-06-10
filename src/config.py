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

secrets = {
    'server_port': 12345,
    'sensor_id': 'Entwicklung',
    'i2c_bus': 0,
    'scl_pin': 21,
    'sda_pin': 20,
    'per_dataacq': True,
    'interval': 10000,
    'server_url': 'https://database3.protronic-gmbh.de/',
    # 'server_url': 'http://10.19.28.29:3021/query?database=PicoTelemetry',
    'use_wdt': True,
}

