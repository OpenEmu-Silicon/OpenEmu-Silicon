// Copyright (c) 2021, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Cocoa

extension Notification.Name {
    /// Posted on the main thread when a background artwork availability check
    /// or image decode (triggered by a cache miss in `isLocalImageAvailable`
    /// or `image`) completes. userInfo[OEDBImageObjectIDKey] carries the
    /// NSManagedObjectID of the OEDBImage that became available.
    static let oeDBImageDidBecomeAvailable = Notification.Name("OEDBImageDidBecomeAvailableNotification")
}
let OEDBImageObjectIDKey = "OEDBImageObjectID"

@objc
final class OEDBImage: OEDBItem {
    
    @objc // OEVersionMigrationController
    static let gameArtworkFormat: NSBitmapImageRep.FileType = .jpeg
    @objc // OEVersionMigrationController
    static let gameArtworkProperties: [NSBitmapImageRep.PropertyKey : Any] = [.compressionFactor : 0.9]
    
    // MARK: - CoreDataProperties
    
    @NSManaged var format: NSNumber
    @NSManaged var height: Float
    @NSManaged var relativePath: String?
    @NSManaged var source: String?
    @NSManaged var width: Float
    @NSManaged var Box: OEDBGame?
    
    // MARK: -
    
    override class var entityName: String { "Image" }
    
    // MARK: -
    
    class func prepareImage(with url: URL) -> [String : Any]? {
        guard let image = NSImage(contentsOf: url)
        else {
            NSLog("File at \(url.absoluteString) is not a valid image.")
            return nil
        }
        
        var result: [String : Any] = ["URL" : url]
        
        let tempInfo = prepareImage(with: image)
        result.merge(tempInfo) { (old, _) in old }
        
        return result
    }
    
    @nonobjc
    class func prepareImage(with image: NSImage) -> [String : Any] {
        
        var result: [String : Any] = [:]
        
        var imageSize = image.size
        let fileName = UUID().uuidString
        let type = gameArtworkFormat
        let properties = gameArtworkProperties
        
        var imageRep: NSBitmapImageRep?
        var maxArea = 0
        for rep in image.representations {
            if let rep = rep as? NSBitmapImageRep {
                let area = rep.pixelsHigh * rep.pixelsWide
                if area >= maxArea {
                    imageRep = rep
                    maxArea = area
                    
                    imageSize.width = CGFloat(rep.pixelsWide)
                    imageSize.height = CGFloat(rep.pixelsHigh)
                }
            }
        }
        
        if imageRep == nil {
            DLog("No NSBitmapImageRep found, creating one…")
            var proposedRect = NSRect(origin: .zero, size: imageSize)
            if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
                imageRep = NSBitmapImageRep(cgImage: cgImage)
            }
        }
        
        guard let imageRep = imageRep else {
            DLog("Could not draw NSImage in NSBitmapimage rep, exiting…")
            return result
        }
        
        let data = imageRep.representation(using: type, properties: properties)
        
        let coverFolderURL = OELibraryDatabase.default!.coverFolderURL
        let imageURL = URL(string: fileName, relativeTo: coverFolderURL)!
        
        do {
            try data?.write(to: imageURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            DLog("Failed to write image file! Exiting…")
            return result
        }
        
        result["width"]        = imageSize.width
        result["height"]       = imageSize.height
        result["relativePath"] = imageURL.relativeString
        result["format"]       = type.rawValue as NSNumber
        
        return result
    }
    
    class func createImage(with dictionary: [String : Any]) -> OEDBImage {
        assert(Thread.isMainThread, "Only call on main thread!")
        return createImage(with: dictionary, in: OELibraryDatabase.default!.mainThreadContext)
    }
    
    class func createImage(with dictionary: [String : Any], in context: NSManagedObjectContext) -> OEDBImage {
        
        let image = OEDBImage.createObject(in: context)
        image.sourceURL = dictionary["URL"] as? URL
        image.width = Float(dictionary["width"] as! CGFloat)
        image.height = Float(dictionary["height"] as! CGFloat)
        
        image.relativePath = dictionary["relativePath"] as? String
        image.format = dictionary["format"] as! NSNumber
        
        return image
    }
    
    // MARK: -
    
    @objc(convertToFormat:withProperties:) // OEVersionMigrationController
    func convert(to type: NSBitmapImageRep.FileType, withProperties attributes: [NSBitmapImageRep.PropertyKey : Any]) -> Bool {
        guard
            let image = image,
            let context = managedObjectContext,
            let newURL = write(image, withType: type, withProperties: attributes, in: context)
        else {
            DLog("converting image failed!")
            return false
        }
        
        context.performAndWait {
            if let url = imageURL {
                try? FileManager.default.removeItem(at: url)
            }
            format = type.rawValue as NSNumber
            relativePath = newURL.relativeString
            save()
        }
        
        return true
    }
    
    // MARK: -
    
    private func write(_ image: NSImage, withType type: NSBitmapImageRep.FileType, withProperties properties: [NSBitmapImageRep.PropertyKey : Any], in context: NSManagedObjectContext) -> URL? {
        
        let imageSize = image.size
        let fileName = UUID().uuidString
        
        var imageRep: NSBitmapImageRep?
        var maxArea = 0
        for rep in image.representations {
            if let rep = rep as? NSBitmapImageRep {
                let area = rep.pixelsHigh * rep.pixelsWide
                if area >= maxArea {
                    imageRep = rep
                    maxArea = area
                }
            }
        }
        
        if imageRep == nil {
            DLog("No NSBitmapImageRep found, creating one…")
            var proposedRect = NSRect(origin: .zero, size: imageSize)
            if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
                imageRep = NSBitmapImageRep(cgImage: cgImage)
            }
        }
        
        guard let imageRep = imageRep else {
            DLog("Could not draw NSImage in NSBitmapimage rep, exiting…")
            return nil
        }
        
        let data = imageRep.representation(using: type, properties: properties)
        
        // TODO: get database from context
        let coverFolderURL = OELibraryDatabase.default!.coverFolderURL
        let imageURL = URL(string: fileName, relativeTo: coverFolderURL)!
        
        do {
            try data?.write(to: imageURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            DLog("Failed to write image file! Exiting…")
            return nil
        }
        
        return imageURL
    }
    
    // MARK: -
    
    override func prepareForDeletion() {
        if managedObjectContext?.parent == nil,
           let url = imageURL {
            // The artwork folder keeps a copy first, so replacing or removing a cover never loses the picture.
            OEArtworkStore.keepCover(self)
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    var uuid: String? {
        return relativePath
    }
    
    private static let decodedImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500
        return cache
    }()

    private var _pendingImageDecodeRelativePath: String?

    /// Synchronous on a cache hit. On a cache miss, kicks off a background
    /// decode and returns nil immediately (a legal value for this property)
    /// so scroll-driven datasource calls never block the main thread on
    /// disk I/O + image decode. Callers should observe
    /// `.oeDBImageDidBecomeAvailable` and reload once the decode completes.
    var image: NSImage? {
        guard let imageURL = imageURL, let key = uuid as NSString? else { return nil }

        if let cached = OEDBImage.decodedImageCache.object(forKey: key) {
            return cached
        }

        let currentRelativePath = relativePath
        if _pendingImageDecodeRelativePath != currentRelativePath {
            _pendingImageDecodeRelativePath = currentRelativePath
            let objectID = self.objectID
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let decoded = NSImage(contentsOf: imageURL)
                DispatchQueue.main.async {
                    guard let self = self, self.relativePath == currentRelativePath else { return }
                    self._pendingImageDecodeRelativePath = nil
                    guard let decoded = decoded else { return }
                    OEDBImage.decodedImageCache.setObject(decoded, forKey: key)
                    NotificationCenter.default.post(name: .oeDBImageDidBecomeAvailable, object: nil,
                                                     userInfo: [OEDBImageObjectIDKey: objectID])
                }
            }
        }
        return nil
    }

    private var _cachedImageURL: URL?
    private var _cachedImageURLRelativePath: String?

    var imageURL: URL? {
        guard let relativePath = relativePath else {
            _cachedImageURL = nil
            _cachedImageURLRelativePath = nil
            return nil
        }
        if let cached = _cachedImageURL, _cachedImageURLRelativePath == relativePath {
            return cached
        }
        let url = libraryDatabase.coverFolderURL.appendingPathComponent(relativePath, isDirectory: false)
        _cachedImageURL = url
        _cachedImageURLRelativePath = relativePath
        return url
    }
    
    var sourceURL: URL? {
        get {
            if let source = source {
                return URL(string: source)
            } else {
                return nil
            }
        }
        set {
            source = newValue?.absoluteString
        }
    }
    
    private var _cachedIsLocalImageAvailable: Bool?
    private var _cachedIsLocalImageAvailableRelativePath: String?

    /// A cheap on-disk existence check (a single stat() call), answered
    /// synchronously and cached per relativePath. This intentionally does NOT
    /// defer to a background check the way `image` does: imageUID() reflects
    /// identity, not availability, but imageRepresentationType()/
    /// imageRepresentation() still key off this to choose between the
    /// placeholder and the real artwork — and IKImageBrowserView caches
    /// representations by UID, so if this answer changed *after* the browser
    /// already asked for a representation under a given UID, the browser
    /// would be told to swap representation kind (placeholder image -> URL)
    /// for an identity it considers unchanged. It doesn't handle that
    /// gracefully — cells go blank/black instead of updating. A stat() call
    /// is cheap enough to answer up front; the actual decode in `image` is
    /// what needed to move off the main thread.
    var isLocalImageAvailable: Bool {
        let currentRelativePath = relativePath
        if let cached = _cachedIsLocalImageAvailable,
           _cachedIsLocalImageAvailableRelativePath == currentRelativePath {
            return cached
        }
        let available = (try? imageURL?.checkResourceIsReachable()) ?? false
        _cachedIsLocalImageAvailable = available
        _cachedIsLocalImageAvailableRelativePath = currentRelativePath
        return available
    }

    func invalidateLocalImageAvailabilityCache() {
        _cachedIsLocalImageAvailable = nil
        _cachedIsLocalImageAvailableRelativePath = nil
    }
}
