// swift-tools-version: 6.0
import PackageDescription

// The package's identity is its repository's name, `hephon-commerce-ios`:
//     .product(name: "HephonCommerce", package: "hephon-commerce-ios")
// Its name is the product's, so Xcode's scheme is `HephonCommerce`.
let package = Package(
    name: "HephonCommerce",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "HephonCommerce", targets: ["HephonCommerce"]),
    ],
    targets: [
        .target(name: "HephonCommerce"),
        .testTarget(
            name: "HephonCommerceTests",
            dependencies: ["HephonCommerce"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
