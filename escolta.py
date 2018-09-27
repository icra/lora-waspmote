#-*- coding: utf-8 -*-
'''
Comunicació serial amb Waspmote SX1272 (gateway)
Continuously listen serial port and handle output

http://www.libelium.com/development/waspmote/documentation/lora-gateway-tutorial/
'''
import serial

#imports locals
import config as c            # see 'config.py'
import processa_missatge as p # see 'processa_missatge.py'

#nova connexió serial
ser          = serial.Serial()
ser.port     = c.port
ser.baudrate = c.baudrate
ser.bytesize = c.bytesize
ser.parity   = c.parity
ser.stopbits = c.stopbits
ser.timeout  = c.timeout
ser.open()

#funció listen
def listen():
  print('Escoltant a',ser.port)
  try:
    while True:
      lines=ser.readlines()
      if len(lines):
        rebut=''.join(str(line) for line in lines)
        p.processa(rebut)
  except KeyboardInterrupt:
    pass

#listen serial port
listen()

