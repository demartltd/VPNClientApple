import XCTest
@testable import Demar_Proxy

final class PayApiParseTests: XCTestCase {
    func testParseCatalog() {
        let catalog = PayApi.parseCatalog([
            "plans": [
                [
                    "tier": "plus",
                    "periods": [
                        [
                            "period": "month",
                            "days": 30,
                            "prices": ["RUB": "199.00", "EUR": "4.00"],
                        ],
                        [
                            "period": "year",
                            "days": 365,
                            "prices": ["RUB": "1599.00", "EUR": "32.00"],
                        ],
                    ],
                ],
                [
                    "tier": "vip",
                    "periods": [
                        [
                            "period": "month",
                            "days": 30,
                            "prices": ["RUB": "399.00", "EUR": "8.00"],
                        ],
                    ],
                ],
            ],
        ])
        XCTAssertEqual(catalog.tiers.count, 2)
        XCTAssertEqual(catalog.price(tier: "plus", period: "month", currency: "RUB"), "199.00")
        XCTAssertEqual(catalog.price(tier: "vip", period: "month", currency: "EUR"), "8.00")
        XCTAssertNil(catalog.price(tier: "free", period: "month", currency: "RUB"))
    }

    func testParseCheckout() {
        let checkout = PayApi.parseCheckout([
            "orderId": "ord_1",
            "payUrl": "https://rollypay.io/pay/abc",
            "amount": "199.00",
            "currency": "RUB",
            "discountPercent": 10,
        ])
        XCTAssertEqual(checkout?.orderId, "ord_1")
        XCTAssertEqual(checkout?.payUrl.absoluteString, "https://rollypay.io/pay/abc")
        XCTAssertEqual(checkout?.amount, "199.00")
        XCTAssertEqual(checkout?.currency, "RUB")
        XCTAssertEqual(checkout?.discountPercent, 10)
    }

    func testParseCheckoutRejectsMissingPayUrl() {
        XCTAssertNil(PayApi.parseCheckout(["orderId": "ord_1", "amount": "1.00"]))
    }

    func testFormatPrice() {
        XCTAssertEqual(PayApi.formatPrice("199.00", currency: "RUB"), "199 ₽")
        XCTAssertEqual(PayApi.formatPrice("4.00", currency: "EUR"), "€4")
        XCTAssertEqual(PayApi.formatPrice("1.50", currency: "EUR"), "€1.5")
    }
}
