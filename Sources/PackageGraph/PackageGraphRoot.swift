//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageModel

import enum TSCUtility.Git

/// Represents the input to the package graph root.
public struct PackageGraphRootInput {
    /// The list of root packages.
    public let packages: [AbsolutePath]

    /// Top level dependencies to the graph.
    public let dependencies: [PackageDependency]

    /// Create a package graph root.
    public init(packages: [AbsolutePath], dependencies: [PackageDependency] = []) {
        self.packages = packages
        self.dependencies = dependencies
    }
}

/// Represents the inputs to the package graph.
public struct PackageGraphRoot {

    /// The root packages.
    public let packages: [PackageIdentity: (reference: PackageReference, manifest: Manifest)]

    /// The root manifests.
    public var manifests: [PackageIdentity: Manifest] {
        return self.packages.compactMapValues { $0.manifest }
    }

    /// The root package references.
    public var packageReferences: [PackageReference] {
        return self.packages.values.map { $0.reference }
    }

    /// The top level dependencies.
    private let _dependencies: [PackageDependency]

    public var dependencies: [PackageDependency] {
        guard let mirrors = mirrors else {
            return self._dependencies
        }

        return self._dependencies.map {
            switch $0 {
            case .fileSystem: return $0
            case .registry: return $0
            case .sourceControl(let settings):
                let mappedLocation: PackageDependency.SourceControl.Location
                switch settings.location {
                case .local:
                    mappedLocation = settings.location
                case .remote(let url):
                    let effectiveLocation = mirrors.effective(for: url.absoluteString)
                    mappedLocation = .remote(SourceControlURL(effectiveLocation))
                }
                return .sourceControl(identity: settings.identity, nameForTargetDependencyResolutionOnly: settings.nameForTargetDependencyResolutionOnly, location: mappedLocation, requirement: settings.requirement, productFilter: settings.productFilter)
            }
        }
    }

    private let mirrors: DependencyMirrors?

    /// Create a package graph root.
    /// Note this quietly skip inputs for which manifests are not found. this could be because the manifest  failed to load or for some other reasons
    // FIXME: This API behavior wrt to non-found manifests is fragile, but required by IDEs
    // it may lead to incorrect assumption in downstream code which may expect an error if a manifest was not found
    // we should refactor this API to more clearly return errors for inputs that do not have a corresponding manifest
    public init(input: PackageGraphRootInput, manifests: [AbsolutePath: Manifest], explicitProduct: String? = nil, mirrors: DependencyMirrors? = nil) {
        self.packages = input.packages.reduce(into: .init(), { partial, inputPath in
            if let manifest = manifests[inputPath]  {
                let packagePath = manifest.path.parentDirectory
                let identity = PackageIdentity(path: packagePath) // this does not use the identity resolver which is fine since these are the root packages
                partial[identity] = (.root(identity: identity, path: packagePath), manifest)
            }
        })

        // FIXME: Deprecate special casing once the manifest supports declaring used executable products.
        // Special casing explicit products like this is necessary to pass the test suite and satisfy backwards compatibility.
        // However, changing the dependencies based on the command line arguments may force pins to temporarily change,
        // which can become a nuisance.
        // Such pin switching can currently be worked around by declaring the executable product as a dependency of a dummy target.
        // But in the future it might be worth providing a way of declaring them in the manifest without a dummy target,
        // at which time the current special casing can be deprecated.
        var adjustedDependencies = input.dependencies
        if let explicitProduct {
            for dependency in manifests.values.lazy.map({ $0.dependenciesRequired(for: .everything) }).joined() {
                adjustedDependencies.append(dependency.filtered(by: .specific([explicitProduct])))
            }
        }

        self._dependencies = adjustedDependencies
        self.mirrors = mirrors
    }

    /// Returns the constraints imposed by root manifests + dependencies.
    public func constraints() throws -> [PackageContainerConstraint] {
        let constraints = self.packageReferences.map {
            PackageContainerConstraint(package: $0, requirement: .unversioned, products: .everything)
        }
        
        let depend = try dependencies.map{
            PackageContainerConstraint(
                package: $0.createPackageRef(),
                requirement: try $0.toConstraintRequirement(),
                products: $0.productFilter
            )
        }
        return constraints + depend
    }
}

extension PackageDependency {
    /// Returns the constraint requirement representation.
    public func toConstraintRequirement() throws -> PackageRequirement {
        switch self {
        case .fileSystem:
            return .unversioned
        case .sourceControl(let settings):
            return try settings.requirement.toConstraintRequirement()
        case .registry(let settings):
            return try settings.requirement.toConstraintRequirement()
        }
    }
}

extension PackageDependency.SourceControl.Requirement {
    /// Returns the constraint requirement representation.
    public func toConstraintRequirement() throws -> PackageRequirement {
        switch self {
        case .range(let range):
            return .versionSet(.range(range))
        case .revision(let identifier):
            return .revision(identifier)
        case .branch(let name):
            return .revision(name)
        case .exact(let version):
            return .versionSet(.exact(version))
        }
    }
}

extension PackageDependency.Registry.Requirement {
    /// Returns the constraint requirement representation.
    public func toConstraintRequirement() throws -> PackageRequirement {
        switch self {
        case .range(let range):
            return .versionSet(.range(range))
        case .exact(let version):
            return .versionSet(.exact(version))
        }
    }
}
