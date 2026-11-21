package dev.yab.browser.engine

import org.junit.Assert.*
import org.junit.Test

class CertificateExceptionTest {
    private val week = CertificateException.PUBLIC_LIVES_MS
    private val month = CertificateException.LOCAL_LIVES_MS

    @Test fun aPublicPardonLivesAWeek() {
        val exception = CertificateException("example.com", 443, listOf("aa"), at = 1_000)
        assertFalse(exception.expired(1_000 + week - 1))
        assertTrue(exception.expired(1_000 + week))
    }

    @Test fun aLocalPardonLivesAMonth() {
        val exception = CertificateException("router.local", 443, listOf("aa"), at = 1_000)
        assertFalse(exception.expired(1_000 + month - 1))
        assertTrue(exception.expired(1_000 + month))
    }

    @Test fun aClockThatMovedBackDoesNotRunAPardonOut() {
        val exception = CertificateException("example.com", 443, listOf("aa"), at = 1_000)
        assertFalse(exception.expired(999))
        assertFalse(exception.expired(0))
    }

    @Test fun theEndpointMatchIgnoresTheCaseAndBracketsOfTheHost() {
        val exception = CertificateException("example.com", 443, listOf("aa"))
        assertTrue(exception.matches("Example.COM", 443))
        assertTrue(CertificateException("2001:db8::1", 443, listOf("aa")).matches("[2001:DB8::1]", 443))
        assertFalse(exception.matches("example.com", 8443))
        assertFalse(exception.matches("other.example.com", 443))
    }

    @Test fun aDifferentChainIsNotTheSamePardon() {
        val exception = CertificateException("example.com", 443, listOf("aa", "bb"))
        assertTrue(exception.chainMatches(listOf("aa", "bb")))
        assertFalse(exception.chainMatches(listOf("aa")))
        assertFalse(exception.chainMatches(listOf("aa", "cc")))
    }

    @Test fun fingerprintsComeFromThePemText() {
        assertEquals(
            listOf(
                "5c632cfd792216e893ca91c2ee074f591aadc17ebf245afd4371744bfa85eed4",
                "c19ba025fcf82099757d40ad71d1b0f17bb8cdfbade187ecd4bb622442cdd517",
            ),
            CertificateException.fingerprints(listOf("pem-a", "pem-b")),
        )
        assertNotEquals(
            CertificateException.fingerprints(listOf("pem-a", "pem-b")),
            CertificateException.fingerprints(listOf("pem-b", "pem-a")),
        )
    }

    @Test fun aHostNameIsLowercasedAndUnwrappedOnlyWhenBracketsCloseIt() {
        assertEquals("example.com", CertificateException.hostName("Example.COM"))
        assertEquals("2001:db8::1", CertificateException.hostName("[2001:DB8::1]"))
        assertEquals("[broken", CertificateException.hostName("[broken"))
    }

    @Test fun aLoopbackNameIsAlsoALocalMachine() {
        assertTrue(AddressKind.isLocal("localhost"))
        assertTrue(AddressKind.isLocal("127.0.0.1"))
        assertTrue(AddressKind.isLocal("192.168.1.4"))
        assertTrue(AddressKind.isLocal("router"))
        assertFalse(AddressKind.isLocal("example.com"))
        assertFalse(AddressKind.isLocal("8.8.8.8"))
    }

    @Test fun privateAddressesAndLocalSuffixesAreLocalMachines() {
        assertTrue(AddressKind.isLocal("10.0.0.5"))
        assertTrue(AddressKind.isLocal("172.16.0.1"))
        assertTrue(AddressKind.isLocal("172.31.255.254"))
        assertTrue(AddressKind.isLocal("169.254.7.7"))
        assertTrue(AddressKind.isLocal("100.64.0.1"))
        assertTrue(AddressKind.isLocal("100.127.255.255"))
        assertTrue(AddressKind.isLocal("0.1.2.3"))
        assertTrue(AddressKind.isLocal("127.8.8.8"))
        assertTrue(AddressKind.isLocal("192.168.0.1"))
        assertFalse(AddressKind.isLocal("100.128.0.1"))
        assertFalse(AddressKind.isLocal("100.63.0.1"))
        assertFalse(AddressKind.isLocal("172.32.0.1"))
        assertFalse(AddressKind.isLocal("172.15.0.1"))
        assertFalse(AddressKind.isLocal("169.255.0.1"))
        assertFalse(AddressKind.isLocal("192.169.0.1"))
        assertTrue(AddressKind.isLocal("printer.local"))
        assertTrue(AddressKind.isLocal("machine.ts.net"))
        assertTrue(AddressKind.isLocal("nas.localhost"))
        assertTrue(AddressKind.isLocal("[::1]"))
        assertTrue(AddressKind.isLocal("[fe80::1]"))
        assertTrue(AddressKind.isLocal("[fc00::5]"))
        assertTrue(AddressKind.isLocal("[fd12:3456:789a:1::1]"))
        assertFalse(AddressKind.isLocal("[2001:db8::1]"))
        assertFalse(AddressKind.isLocal("[12345::1]"))
        assertFalse(AddressKind.isLocal("[::1"))
        assertFalse(AddressKind.isLocal("[not-hex::1]"))
        assertFalse(AddressKind.isLocal("["))
        assertFalse(AddressKind.isLocal("[:1]"))
    }

    @Test fun invalidInputIsNeverALocalMachine() {
        assertFalse(AddressKind.isLocal(""))
        assertFalse(AddressKind.isLocal("999.1.1.1"))
        assertFalse(AddressKind.isLocal("256.1.1.1"))
        assertFalse(AddressKind.isLocal("example.com."))
    }

    @Test fun aColonHostIsExaminedInsideBrackets() {
        assertEquals(CertificateException.LOCAL_LIVES_MS, CertificateException("::1", 443, listOf("aa")).lives())
        assertEquals(CertificateException.LOCAL_LIVES_MS, CertificateException("fe80::1", 443, listOf("aa")).lives())
        assertEquals(CertificateException.LOCAL_LIVES_MS, CertificateException("fd12:3456:789a:1::1", 443, listOf("aa")).lives())
        assertEquals(CertificateException.PUBLIC_LIVES_MS, CertificateException("2001:db8::1", 443, listOf("aa")).lives())
    }
}