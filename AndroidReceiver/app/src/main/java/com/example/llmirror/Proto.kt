package com.example.llmirror

/** Константы протокола (совпадают со StreamingProtocolAndTransport.swift на iPhone). */
object Proto {
    const val MAGIC = 0x4C
    const val HEADER = 24
    const val DEFAULT_PORT = 5004
    const val SERVICE_TYPE = "_llmirror._udp."

    const val T_CONFIG = 0x01
    const val T_IDR = 0x02
    const val T_SLICE = 0x03
    const val T_AUDIO = 0x04
    const val T_PLI = 0x10
    const val T_PING = 0x11
    const val T_PONG = 0x12
    const val T_STOP = 0xFF

    const val CODEC_H264 = 1
    const val CODEC_HEVC = 2
}
