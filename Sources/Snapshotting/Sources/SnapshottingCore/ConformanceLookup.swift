//
//  ConformanceLookup.swift
//
//
//  Created by Noah Martin on 7/3/23.
//

import Foundation
import MachO

private func getTypeName(descriptor: UnsafePointer<TargetModuleContextDescriptor>) -> String? {
  let flags = descriptor.pointee.flags
  var parentName: String? = nil
  switch flags.kind {
  case .Module, .Enum, .Struct, .Class:
    let name = UnsafeRawPointer(descriptor)
      .advanced(by: MemoryLayout<TargetModuleContextDescriptor>.offset(of: \.name)!)
      .advanced(by: Int(descriptor.pointee.name))
      .assumingMemoryBound(to: CChar.self)
    let typeName = String(cString: name)
    if descriptor.pointee.parent != 0 {
      let parent = UnsafeRawPointer(descriptor).advanced(by: MemoryLayout<TargetModuleContextDescriptor>.offset(of: \.parent)!).advanced(by: Int(descriptor.pointee.parent))
      if abs(descriptor.pointee.parent) % 2 == 1 {
        return nil
      }
      parentName = getTypeName(descriptor: parent.assumingMemoryBound(to: TargetModuleContextDescriptor.self))
    }
    if let parentName = parentName {
      return "\(parentName).\(typeName)"
    }
    return typeName
  default:
    return nil
  }
}

typealias LookupResult = (name: String, accessor: () -> UInt64, proto: String)

private func parseConformance(conformance: UnsafePointer<ProtocolConformanceDescriptor>) -> LookupResult? {
  let flags = conformance.pointee.conformanceFlags

  guard case .DirectTypeDescriptor = flags.kind else {
    return nil
  }

  guard conformance.pointee.protocolDescriptor % 2 == 1 else {
    return nil
  }
  let descriptorOffset = Int(conformance.pointee.protocolDescriptor & ~1)
  let jumpPtr = UnsafeRawPointer(conformance).advanced(by: MemoryLayout<ProtocolConformanceDescriptor>.offset(of: \.protocolDescriptor)!).advanced(by: descriptorOffset)
  let address = jumpPtr.load(as: UInt64.self)
  let protoPtr = UnsafeRawPointer(bitPattern: UInt(address))!
  let proto = protoPtr.load(as: ProtocolDescriptor.self)
  let namePtr = protoPtr.advanced(by: MemoryLayout<ProtocolDescriptor>.offset(of: \.name)!).advanced(by: Int(proto.name))
  let protocolName = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
  guard ["PreviewProvider", "PreviewRegistry"].contains(protocolName) else {
    return nil
  }

  let typeDescriptorPointer = UnsafeRawPointer(conformance).advanced(by: MemoryLayout<ProtocolConformanceDescriptor>.offset(of: \.nominalTypeDescriptor)!).advanced(by: Int(conformance.pointee.nominalTypeDescriptor))

  let descriptor = typeDescriptorPointer.assumingMemoryBound(to: TargetModuleContextDescriptor.self)
  if let name = getTypeName(descriptor: descriptor),
     [ContextDescriptorKind.Class, ContextDescriptorKind.Struct, ContextDescriptorKind.Enum].contains(descriptor.pointee.flags.kind) {
    let accessFunctionPointer = UnsafeRawPointer(descriptor).advanced(by: MemoryLayout<TargetModuleContextDescriptor>.offset(of: \.accessFunction)!).advanced(by: Int(descriptor.pointee.accessFunction))
    let accessFunction = unsafeBitCast(accessFunctionPointer, to: (@convention(c) () -> UInt64).self)
    return (name, accessFunction, protocolName)
  }
  return nil
}

func getPreviewTypes() -> [LookupResult] {
  let images = _dyld_image_count()
  var types = [LookupResult]()
  for i in 0..<images {
    let imageName = String(cString: _dyld_get_image_name(i))
    // System frameworks on the simulator are in Xcode.app/Contents/** (Although Xcode could be renamed like Xcode-beta.app so don't check for that specifically)
    guard !imageName.contains(".simruntime") && !imageName.contains(".app/Contents/") && !imageName.starts(with: "/usr/lib/") else {
      continue
    }

    let header = _dyld_get_image_header(i)!
    var size: UInt = 0
    let sectStart = UnsafeRawPointer(
      getsectiondata(
        UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self),
        "__TEXT",
        "__swift5_proto",
        &size))?.assumingMemoryBound(to: Int32.self)
    if var sectData = sectStart {
      for _ in 0..<Int(size)/MemoryLayout<Int32>.size {
        let conformance = UnsafeRawPointer(sectData)
          .advanced(by: Int(sectData.pointee))
          .assumingMemoryBound(to: ProtocolConformanceDescriptor.self)
        if let result = parseConformance(conformance: conformance) {
          types.append(result)
        }
        sectData = sectData.successor()
      }
    }
  }
  return types
}
