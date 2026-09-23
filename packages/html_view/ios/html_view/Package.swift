// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "html_view",
  platforms: [
    .iOS("13.0")
  ],
  products: [
    .library(name: "html-view", targets: ["html_view"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "html_view",
      dependencies: []
    )
  ]
)
