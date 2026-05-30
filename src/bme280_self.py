# -*- coding: utf-8 -*-
"""
bme280_self.py
Created on Thu Mar 20 10:31:30 2025
@author: Armin Ludwig
"""

from machine import I2C
import time
from i2c_device import Device

# setting BME280 default address.
BME280_I2CADDR = 0x76

# Operating Modes
BME280_OSAMPLE_1 = 1  # BME280_ULTRALOWPOWER
BME280_OSAMPLE_2 = 2  # BME280_LOWPOWER
BME280_OSAMPLE_4 = 3  # BME280_STANDARD
BME280_OSAMPLE_8 = 4  # BME280_HIGHRES
BME280_OSAMPLE_16 = 5 # BME280_ULTRAHIGHRES

# BME280 Registers
BME280_REGISTER_DIG_T1 = 0x88  # Temperature calibration data
BME280_REGISTER_DIG_T2 = 0x8A
BME280_REGISTER_DIG_T3 = 0x8C

BME280_REGISTER_DIG_P1 = 0x8E  # Pressure calibration data
BME280_REGISTER_DIG_P2 = 0x90
BME280_REGISTER_DIG_P3 = 0x92
BME280_REGISTER_DIG_P4 = 0x94
BME280_REGISTER_DIG_P5 = 0x96
BME280_REGISTER_DIG_P6 = 0x98
BME280_REGISTER_DIG_P7 = 0x9A
BME280_REGISTER_DIG_P8 = 0x9C
BME280_REGISTER_DIG_P9 = 0x9E

BME280_REGISTER_DIG_H1 = 0xA1  # Humidity calibration data
BME280_REGISTER_DIG_H2 = 0xE1
BME280_REGISTER_DIG_H3 = 0xE3
BME280_REGISTER_DIG_H4 = 0xE4
BME280_REGISTER_DIG_H5 = 0xE5
BME280_REGISTER_DIG_H6 = 0xE6
BME280_REGISTER_DIG_H7 = 0xE7

# Ch5.4
BME280_REGISTER_CHIPID = 0xD0    # Device ID
BME280_REGISTER_VERSION = 0xD1   # Version Number
BME280_REGISTER_SOFTRESET = 0xE0 # Software reset command

BME280_REGISTER_CONTROL_HUM = 0xF2 # Humidity control register
# Humidity oversampling(Ch3.6)
BME280_REGISTER_CONTROL = 0xF4     # Main control register
# 7-5: Temperature oversampling(Ch3.6); 4-2: Preassure oversampling(Ch3.6); 1-0: mode(Ch3.3)
BME280_REGISTER_CONFIG = 0xF5      # Cofiguration settings
# 7-5: Standby Time in normal mode (T_sb); 4-2: IIR-Filter coefficient; 0: I2C/SPI
# table27page30
#default: 0x00 -> T_sb=0.5ms; no IIR-Filter; I2C-mode

# RAW-DATA REGISTERS 
BME280_REGISTER_PRESSURE_DATA = 0xF7
BME280_REGISTER_TEMP_DATA = 0xFA # First Byte -> MSB (0xFB -> LSB, 0xFC -> XLSB)
BME280_REGISTER_HUMIDITY_DATA = 0xFD

class BME280:
  def __init__(self, osmode=BME280_OSAMPLE_1, address=BME280_I2CADDR, i2c=None,
               **kwargs):
    # Check that mode is valid.
    if osmode not in [BME280_OSAMPLE_1, BME280_OSAMPLE_2, BME280_OSAMPLE_4,
                    BME280_OSAMPLE_8, BME280_OSAMPLE_16]:
        raise ValueError(
            'Unexpected mode value {0}. Set mode to one of '
            'BME280_ULTRALOWPOWER, BME_LOWPOWER, BME280_STANDARD, BME280_HIGHRES, or '
            'BME280_ULTRAHIGHRES'.format(osmode))
    self._osmode = osmode
    # Create I2C device.
    if i2c is None:
      raise ValueError('An I2C object is required.')
    self._device = Device(address, i2c)
    # Load calibration values.
    self._load_calibration()
    self._device.write8(BME280_REGISTER_CONTROL, 0x3F)
    self.t_fine = 0

  def _load_calibration(self):

    self.dig_T1 = self._device.readU16LE(BME280_REGISTER_DIG_T1)
    self.dig_T2 = self._device.readS16LE(BME280_REGISTER_DIG_T2)
    self.dig_T3 = self._device.readS16LE(BME280_REGISTER_DIG_T3)

    self.dig_P1 = self._device.readU16LE(BME280_REGISTER_DIG_P1)
    self.dig_P2 = self._device.readS16LE(BME280_REGISTER_DIG_P2)
    self.dig_P3 = self._device.readS16LE(BME280_REGISTER_DIG_P3)
    self.dig_P4 = self._device.readS16LE(BME280_REGISTER_DIG_P4)
    self.dig_P5 = self._device.readS16LE(BME280_REGISTER_DIG_P5)
    self.dig_P6 = self._device.readS16LE(BME280_REGISTER_DIG_P6)
    self.dig_P7 = self._device.readS16LE(BME280_REGISTER_DIG_P7)
    self.dig_P8 = self._device.readS16LE(BME280_REGISTER_DIG_P8)
    self.dig_P9 = self._device.readS16LE(BME280_REGISTER_DIG_P9)

    self.dig_H1 = self._device.readU8(BME280_REGISTER_DIG_H1)
    self.dig_H2 = self._device.readS16LE(BME280_REGISTER_DIG_H2)
    self.dig_H3 = self._device.readU8(BME280_REGISTER_DIG_H3)
    self.dig_H6 = self._device.readS8(BME280_REGISTER_DIG_H7)

    h4 = self._device.readS8(BME280_REGISTER_DIG_H4)
    h4 = (h4 << 24) >> 20
    self.dig_H4 = h4 | (self._device.readU8(BME280_REGISTER_DIG_H5) & 0x0F)

    h5 = self._device.readS8(BME280_REGISTER_DIG_H6)
    h5 = (h5 << 24) >> 20
    self.dig_H5 = h5 | (
        self._device.readU8(BME280_REGISTER_DIG_H5) >> 4 & 0x0F)

  def read_raw_temp(self):
    """Reads the raw (uncompensated) temperature from the sensor."""
    meas = self._osmode
    self._device.write8(BME280_REGISTER_CONTROL_HUM, meas)
    meas = self._osmode << 5 | self._osmode << 2 | 0b01   # 0b01 -> forced mode
    self._device.write8(BME280_REGISTER_CONTROL, meas) # osmode=3 -> 011 011 01
    sleep_time = 1250 + 2300 * (1 << self._osmode)

    sleep_time = sleep_time + 2300 * (1 << self._osmode) + 575
    sleep_time = sleep_time + 2300 * (1 << self._osmode) + 575
    time.sleep_us(sleep_time)  # Wait the required time
    msb = self._device.readU8(BME280_REGISTER_TEMP_DATA)     # 0xFA
    lsb = self._device.readU8(BME280_REGISTER_TEMP_DATA + 1) # 0xFB
    xlsb = self._device.readU8(BME280_REGISTER_TEMP_DATA + 2)# 0xFC
    raw = ((msb << 16) | (lsb << 8) | xlsb) >> 4
    return raw

  def read_raw_pressure(self):
    """Reads the raw (uncompensated) pressure level from the sensor."""
    """Assumes that the temperature has already been read """
    """i.e. that enough delay has been provided"""
    msb = self._device.readU8(BME280_REGISTER_PRESSURE_DATA)
    lsb = self._device.readU8(BME280_REGISTER_PRESSURE_DATA + 1)
    xlsb = self._device.readU8(BME280_REGISTER_PRESSURE_DATA + 2)
    raw = ((msb << 16) | (lsb << 8) | xlsb) >> 4
    return raw

  def read_raw_humidity(self):
    """Assumes that the temperature has already been read """
    """i.e. that enough delay has been provided"""
    msb = self._device.readU8(BME280_REGISTER_HUMIDITY_DATA)
    lsb = self._device.readU8(BME280_REGISTER_HUMIDITY_DATA + 1)
    raw = (msb << 8) | lsb
    return raw

  def read_temperature(self):
    """Get the compensated temperature in 0.01 of a degree celsius."""
    adc = self.read_raw_temp()
    var1 = ((adc >> 3) - (self.dig_T1 << 1)) * (self.dig_T2 >> 11)
    var2 = ((
        (((adc >> 4) - self.dig_T1) * ((adc >> 4) - self.dig_T1)) >> 12) *
        self.dig_T3) >> 14
    self.t_fine = var1 + var2 # used for Humidity and Pressure compensation
    return (self.t_fine * 5 + 128) >> 8

  def read_pressure(self):
    """Gets the compensated pressure in Pascals."""
    adc = self.read_raw_pressure()
    var1 = self.t_fine - 128000
    var2 = var1 * var1 * self.dig_P6
    var2 = var2 + ((var1 * self.dig_P5) << 17)
    var2 = var2 + (self.dig_P4 << 35)
    var1 = (((var1 * var1 * self.dig_P3) >> 8) +
            ((var1 * self.dig_P2) >> 12))
    var1 = (((1 << 47) + var1) * self.dig_P1) >> 33
    if var1 == 0:
      return 0
    p = 1048576 - adc
    p = (((p << 31) - var2) * 3125) // var1
    var1 = (self.dig_P9 * (p >> 13) * (p >> 13)) >> 25
    var2 = (self.dig_P8 * p) >> 19
    return ((p + var1 + var2) >> 8) + (self.dig_P7 << 4)

  def read_humidity(self):
    adc = self.read_raw_humidity()
    # print 'Raw humidity = {0:d}'.format (adc)
    h = self.t_fine - 76800
    h = (((((adc << 14) - (self.dig_H4 << 20) - (self.dig_H5 * h)) +
         16384) >> 15) * (((((((h * self.dig_H6) >> 10) * (((h *
                          self.dig_H3) >> 11) + 32768)) >> 10) + 2097152) *
                          self.dig_H2 + 8192) >> 14))
    h = h - (((((h >> 15) * (h >> 15)) >> 7) * self.dig_H1) >> 4)
    h = 0 if h < 0 else h
    h = 419430400 if h > 419430400 else h
    return h >> 12

  @property
  def temperature(self):
    "Return the temperature in degrees."
    t = self.read_temperature()
    return round(t / 100, 2)

  @property
  def pressure(self):
    "Return the temperature in hPa."
    p = self.read_pressure() // 256
    return round(p / 100, 2)

  @property
  def humidity(self):
    "Return the humidity in percent."
    h = self.read_humidity()
    hi = h // 1024
    #hd = h * 100 // 1024 - hi * 100
    #return "{}.{:02d}%".format(hi, hd)
    hd = h / 1024 - hi
    return round(hi+hd, 2)