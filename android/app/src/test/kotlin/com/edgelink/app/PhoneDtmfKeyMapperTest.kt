package com.edgelink.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneDtmfKeyMapperTest {
    @Test
    fun sanitizesIvrSequences() {
        assertEquals("12#*", PhoneDtmfKeyMapper.sanitizeSequence("1 2 # *"))
        assertEquals("1,2#*", PhoneDtmfKeyMapper.sanitizeSequence("1p2＃＊"))
    }

    @Test
    fun rejectsInvalidOrEmptySequences() {
        assertNull(PhoneDtmfKeyMapper.sanitizeSequence(""))
        assertNull(PhoneDtmfKeyMapper.sanitizeSequence(",,"))
        assertNull(PhoneDtmfKeyMapper.sanitizeSequence("abc1"))
    }

    @Test
    fun identifiesDtmfToneChars() {
        assertTrue(PhoneDtmfKeyMapper.isTone('0'))
        assertTrue(PhoneDtmfKeyMapper.isTone('9'))
        assertTrue(PhoneDtmfKeyMapper.isTone('*'))
        assertTrue(PhoneDtmfKeyMapper.isTone('#'))
        assertFalse(PhoneDtmfKeyMapper.isTone(','))
    }
}
