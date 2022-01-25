//
//  RswiftCore.swift
//  R.swift
//
//  Created by Tom Lokhorst on 2017-04-22.
//  From: https://github.com/mac-cain13/R.swift
//  License: MIT License
//

import Foundation
import XcodeEdit

public typealias RswiftGenerator = Generator
public enum Generator: String, CaseIterable {
  case image
  case string
  case color
  case file
  case font
  case nib
  case segue
  case storyboard
  case reuseIdentifier
  case entitlements
  case info
  case id
}

public struct RswiftCore {
  private let callInformation: CallInformation

  public init(_ callInformation: CallInformation) {
    self.callInformation = callInformation
  }

  public func run() throws {
    do {
      let xcodeproj = try Xcodeproj(url: callInformation.xcodeprojURL)
      let ignoreFile = (try? IgnoreFile(ignoreFileURL: callInformation.rswiftIgnoreURL)) ?? IgnoreFile()

      printWarningAboutDependencyAnalysis(for: try xcodeproj.scriptBuildPhases(forTarget: callInformation.targetName))

      let buildConfigurations = try xcodeproj.buildConfigurations(forTarget: callInformation.targetName)

      let resourceURLs = try xcodeproj.resourcePaths(forTarget: callInformation.targetName)
        .map { path in path.url(with: callInformation.urlForSourceTreeFolder) }
        .compactMap { $0 }
        .filter { !ignoreFile.matches(url: $0) }

      let resources = Resources(resourceURLs: resourceURLs, fileManager: FileManager.default)
      let infoPlistWhitelist = ["UIApplicationShortcutItems", "UIApplicationSceneManifest", "NSUserActivityTypes", "NSExtension"]

      var structGenerators: [StructGenerator] = []
      if callInformation.generators.contains(.image) {
        structGenerators.append(ImageStructGenerator(assetFolders: resources.assetFolders, images: resources.images))
      }
      if callInformation.generators.contains(.color) {
        structGenerators.append(ColorStructGenerator(assetFolders: resources.assetFolders))
      }
      if callInformation.generators.contains(.font) {
        structGenerators.append(FontStructGenerator(fonts: resources.fonts))
      }
      if callInformation.generators.contains(.segue) {
        structGenerators.append(SegueStructGenerator(storyboards: resources.storyboards))
      }
      if callInformation.generators.contains(.storyboard) {
        structGenerators.append(StoryboardStructGenerator(storyboards: resources.storyboards))
      }
      if callInformation.generators.contains(.nib) {
        structGenerators.append(NibStructGenerator(nibs: resources.nibs))
      }
      if callInformation.generators.contains(.reuseIdentifier) {
        structGenerators.append(ReuseIdentifierStructGenerator(reusables: resources.reusables))
      }
      if callInformation.generators.contains(.file) {
        structGenerators.append(ResourceFileStructGenerator(resourceFiles: resources.resourceFiles))
      }
      if callInformation.generators.contains(.string) {
        structGenerators.append(StringsStructGenerator(localizableStrings: resources.localizableStrings, developmentLanguage: xcodeproj.developmentLanguage))
      }
      if callInformation.generators.contains(.id) {
        structGenerators.append(AccessibilityIdentifierStructGenerator(nibs: resources.nibs, storyboards: resources.storyboards))
      }
      if callInformation.generators.contains(.info) {

        let infoPlists = buildConfigurations.compactMap { config -> PropertyList? in
          guard let infoPlistFile = callInformation.infoPlistFile else { return nil }
          return loadPropertyList(name: config.name, url: infoPlistFile, callInformation: callInformation)
        }

        structGenerators.append(PropertyListGenerator(name: "info", plists: infoPlists, toplevelKeysWhitelist: infoPlistWhitelist))
      }
      if callInformation.generators.contains(.entitlements) {

        let entitlements = buildConfigurations.compactMap { config -> PropertyList? in
          guard let codeSignEntitlement = callInformation.codeSignEntitlements else { return nil }
          return loadPropertyList(name: config.name, url: codeSignEntitlement, callInformation: callInformation)
        }

        structGenerators.append(PropertyListGenerator(name: "entitlements", plists: entitlements, toplevelKeysWhitelist: nil))
      }

      // Generate regular R file
      let fileContents = generateRegularFileContents(resources: resources, generators: structGenerators)
      writeIfChanged(contents: fileContents, toURL: callInformation.outputURL)

      // Generate UITest R file
      if let uiTestOutputURL = callInformation.uiTestOutputURL {
        let uiTestFileContents = generateUITestFileContents(resources: resources, generators: [
          AccessibilityIdentifierStructGenerator(nibs: resources.nibs, storyboards: resources.storyboards)
        ])
        writeIfChanged(contents: uiTestFileContents, toURL: uiTestOutputURL)
      }

    } catch let error as ResourceParsingError {
      switch error {
      case let .parsingFailed(description):
        fail(description)

      case let .unsupportedExtension(givenExtension, supportedExtensions):
        let joinedSupportedExtensions = supportedExtensions.joined(separator: ", ")
        fail("File extension '\(String(describing: givenExtension))' is not one of the supported extensions: \(joinedSupportedExtensions)")
      }

      exit(EXIT_FAILURE)
    }
  }

  private func printWarningAboutDependencyAnalysis(for scriptBuildPhases: [PBXShellScriptBuildPhase]) {
    let outputFiles = [
      callInformation.outputURL.path,
      callInformation.outputURL.path.replacingOccurrences(of: callInformation.sourceRootURL.path, with: "$SOURCE_ROOT"),
      callInformation.outputURL.path.replacingOccurrences(of: callInformation.sourceRootURL.path, with: "$SRCROOT"),
      callInformation.outputURL.path.replacingOccurrences(of: callInformation.sourceRootURL.path, with: "$(SOURCE_ROOT)"),
      callInformation.outputURL.path.replacingOccurrences(of: callInformation.sourceRootURL.path, with: "$(SRCROOT)"),
    ]

    let rswiftPhase = scriptBuildPhases.first { buildPhase in
      let outputs = buildPhase.outputPaths ?? []
      let script = buildPhase.shellScript

      return script.contains("rswift") && outputs.contains { outputFiles.contains($0) }
    }

    if let rswiftPhase = rswiftPhase {
      if rswiftPhase.alwaysOutOfDate != true {
        warn("In R.swift Run Script build phase, disable \"Based on dependency analysis\"")
      }
    }
  }

  private func generateRegularFileContents(resources: Resources, generators: [StructGenerator]) -> String {
    let aggregatedResult = AggregatedStructGenerator(subgenerators: generators)
      .generatedStructs(at: callInformation.accessLevel, prefix: "")

    let (externalStructWithoutProperties, internalStruct) = ValidatedStructGenerator(validationSubject: aggregatedResult)
      .generatedStructs(at: callInformation.accessLevel, prefix: "")

    let externalStruct = externalStructWithoutProperties
      .addingInternalProperties(forBundleIdentifier: callInformation.bundleIdentifier, hostingBundle: callInformation.hostingBundle)

    let codeConvertibles: [SwiftCodeConverible?] = [
      HeaderPrinter(),
      ImportPrinter(
        modules: callInformation.imports,
        extractFrom: [externalStruct, internalStruct],
        exclude: [Module.custom(name: callInformation.productModuleName)]
      ),
      extract(externalStruct.structs),
      externalStruct,
      internalStruct
    ]

    return codeConvertibles
      .compactMap { $0?.swiftCode }
      .joined(separator: "\n\n")
      + "\n" // Newline at end of file
  }

  private func generateUITestFileContents(resources: Resources, generators: [StructGenerator]) -> String {
    let (externalStruct, _) =  AggregatedStructGenerator(subgenerators: generators)
      .generatedStructs(at: callInformation.accessLevel, prefix: "")

    let codeConvertibles: [SwiftCodeConverible?] = [
      HeaderPrinter(),
      externalStruct
    ]

    return codeConvertibles
      .compactMap { $0?.swiftCode }
      .joined(separator: "\n\n")
      + "\n" // Newline at end of file
  }
}

private func loadPropertyList(name: String, url: URL, callInformation: CallInformation) -> PropertyList? {
  do {
    return try PropertyList(buildConfigurationName: name, url: url)
  } catch let ResourceParsingError.parsingFailed(humanReadableError) {
    warn(humanReadableError)
    return nil
  }
  catch {
    return nil
  }
}

private func writeIfChanged(contents: String, toURL outputURL: URL) {
  let currentFileContents = try? String(contentsOf: outputURL, encoding: .utf8)
  guard currentFileContents != contents else { return }
  do {
    try contents.write(to: outputURL, atomically: true, encoding: .utf8)
  } catch {
    fail(error.localizedDescription)
  }
}



private let themes = ["light", "dark"]

private func extract(_ list: [Struct]) -> Extn {
  var structs: [Strt] = []

  if let image = list.first(where: { "\($0.type)" == "image" }) {
    let suffixs = themes.map { "_" + $0 }

    let folders = image.structs.map { folder -> Strt in
      let functions = folder.functions
        .filter { function in
          suffixs[1...].first { "\(function.name)".hasSuffix($0) } == nil
        }
        .map { function in
          image_function("\(folder.type)", "\(function.name)")
        }
      return Strt(type: folder.type, functions: functions, structs: [])
    }

    structs.append(Strt(type: Type(module: .host, name: "img"), functions: [], structs: folders))
  }

  if let string = list.first(where: { "\($0.type)" == "string" }) {
    let tables = string.structs.map { table -> Strt in
      let functions = table.functions
        .map { function in
          string_function("\(table.type)", "\(function.name)")
        }
      return Strt(type: table.type, functions: functions, structs: [])
    }

    structs.append(Strt(type: Type(module: .host, name: "str"), functions: [], structs: tables))
  }

  return Extn(structs: structs)
}

private func image_function(_ folder: String, _ function: String) -> Function {
  if function.hasSuffix("_\(themes[0])") {
    let beg = function.startIndex
    let end = function.index(function.startIndex, offsetBy: function.count-themes[0].count-1)
    let name = String(function[beg..<end])
    let body = "(code ?? theme()) == \"dark\" ? R.image.\(folder).\(name)_dark() : R.image.\(folder).\(name)_light()"
    // var body = "switch code ?? theme() {\n"
    // body += themes
    //   .map { "case \"\($0)\": return R.image.\(folder).\(name)_\($0)()" }
    //   .joined(separator: "\n")
    // body += "\ndefault: return nil"
    // body += "\n}"
    return Function(availables: [],
                    comments: [],
                    accessModifier: .internalLevel,
                    isStatic: true,
                    name: SwiftIdentifier(name: name),
                    generics: nil,
                    parameters: [Function.Parameter(name: "_", localName: "code", type: Type(module: .stdLib, name: "String").asOptional(), defaultValue: "nil")],
                    doesThrow: false,
                    returnType: Type(module: .host, name: "UIImage").asOptional(),
                    body: body,
                    os: []
    )
  } else {
    let name = function
    let body = "R.image.\(folder).\(name)()"
    return Function(availables: [],
                    comments: [],
                    accessModifier: .internalLevel,
                    isStatic: true,
                    name: SwiftIdentifier(name: name),
                    generics: nil,
                    parameters: [],
                    doesThrow: false,
                    returnType: Type(module: .host, name: "UIImage").asOptional(),
                    body: body,
                    os: []
    )
  }
}

private func string_function(_ table: String, _ function: String) -> Function {

  let name = function
  let body = "R.string.\(table).\(name)(preferredLanguages: [code ?? language()])"

  return Function(availables: [],
                  comments: [],
                  accessModifier: .internalLevel,
                  isStatic: true,
                  name: SwiftIdentifier(name: name),
                  generics: nil,
                  parameters: [Function.Parameter(name: "_", localName: "code", type: Type(module: .stdLib, name: "String").asOptional(), defaultValue: "nil")],
                  doesThrow: false,
                  returnType: Type(module: .stdLib, name: "String"),
                  body: body,
                  os: []
  )
}

struct Extn: SwiftCodeConverible {
  var structs: [Strt]
  var swiftCode: String {
    let variableString = """
      static var theme: ()->String = { "" }
      static var language: ()->String = { "" }
    """
    let structsString = structs
      .map { $0.swiftCode }
      .sorted()
      .map { $0.description }
      .joined(separator: "\n\n")
      .indent(with: "  ")
    return "extension R {\n\(variableString)\n\n\(structsString)\n}"
  }

}

struct Strt: UsedTypesProvider, SwiftCodeConverible {
  let type: Type
  var functions: [Function]
  var structs: [Strt]

  var usedTypes: [UsedType] {
    return [
      type.usedTypes,
      functions.flatMap(getUsedTypes),
      structs.flatMap(getUsedTypes),
    ]
      .joined()
      .array()
  }

  var swiftCode: String {
    let functionsString = functions
      .map { $0.swiftCode }
      .sorted()
      .map { $0.description }
      .joined(separator: "\n")

    let structsString = structs
      .map { $0.swiftCode }
      .sorted()
      .map { $0.description }
      .joined(separator: "\n\n")

    let components = [functionsString, structsString].filter { !($0.isEmpty) }
    let string = components.joined(separator: "\n\n").indent(with: "  ")

    return "struct \(type) {\n\(string)\n}"
  }
}
