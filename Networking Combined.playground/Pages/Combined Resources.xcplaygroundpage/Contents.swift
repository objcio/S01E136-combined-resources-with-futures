import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true


enum HttpMethod<Body> {
    case get
    case post(Body)
}

extension HttpMethod {
    var method: String {
        switch self {
        case .get: return "GET"
        case .post: return "POST"
        }
    }
}

struct Resource<A> {
    var urlRequest: URLRequest
    let parse: (Data) -> A?
}

extension Resource {
    func map<B>(_ transform: @escaping (A) -> B) -> Resource<B> {
        return Resource<B>(urlRequest: urlRequest) { self.parse($0).map(transform) }
    }
}

extension Resource where A: Decodable {
    init(get url: URL) {
        self.urlRequest = URLRequest(url: url)
        self.parse = { data in
            try? JSONDecoder().decode(A.self, from: data)
        }
    }

    init<Body: Encodable>(url: URL, method: HttpMethod<Body>) {
        urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method.method
        switch method {
        case .get: ()
        case .post(let body):
            self.urlRequest.httpBody = try! JSONEncoder().encode(body)
        }
        self.parse = { data in
            try? JSONDecoder().decode(A.self, from: data)
        }
    }
}

extension URLSession {
    func load<A>(_ resource: Resource<A>, completion: @escaping (A?) -> ()) {
        dataTask(with: resource.urlRequest) { data, _, _ in
            completion(data.flatMap(resource.parse))
        }.resume()
    }
}

struct Episode: Codable {
    var number: Int
    var title: String
}

struct Collection: Codable {
    var title: String
}

let resource = Resource<[Episode]>(get: URL(string: "https://talk.objc.io/episodes.json")!)
let collections = Resource<[Collection]>(get: URL(string: "https://talk.objc.io/collections.json")!)
let latestCollection = collections.map { $0.first }

// We have up until here --------------------------------------------------

indirect enum CombinedResource<A> {
    case resource(Resource<A>)
    case _sequence(CombinedResource<Any>, (Any) -> CombinedResource<A>)
    case _parallel(CombinedResource<Any>, CombinedResource<Any>)
    case _mapped(CombinedResource<Any>, (Any) -> A)
}

extension CombinedResource {
    var asAny: CombinedResource<Any> {
        switch self {
        case .resource(let r):
            return .resource(r.map { $0 })
        case let ._sequence(x, y):
            return ._sequence(x, { y($0).asAny })
        case let ._parallel(x, y):
            return ._parallel(x, y)
        case let ._mapped(x, transform):
            return ._mapped(x, { transform($0) })
        }
    }
    
    func flatMap<B>(_ transform: @escaping (A) -> CombinedResource<B>) -> CombinedResource<B> {
        return ._sequence(self.asAny, { any in transform(any as! A) })
    }
    
    func zip<B>(_ other: CombinedResource<B>) -> CombinedResource<(A,B)> {
        return ._parallel(self.asAny, other.asAny)
    }
    
    func map<B>(_ transform: @escaping (A) -> B) -> CombinedResource<B> {
        return ._mapped(self.asAny, { transform($0 as! A) })
    }
}

extension Resource {
    var c: CombinedResource<A> {
        return .resource(self)
    }
}

extension URLSession {
    func load<A>(_ c: CombinedResource<A>, completion: @escaping (A?) -> ()) {
        switch c {
        case .resource(let r):
            load(r, completion: completion)
        case let ._sequence(x, y):
            load(x, completion: {
                guard let v = $0 else { completion(nil); return }
                self.load(y(v), completion: completion)
            })
        case let ._parallel(x, y):
            let g = DispatchGroup()
            g.enter()
            var resultA: Any?
            var resultB: Any?
            load(x) {
                resultA = $0
                g.leave()
            }
            g.enter()
            load(y) {
                resultB = $0
                g.leave()
            }
            g.notify(queue: .global(qos: .userInitiated)) {
                self.delegateQueue.addOperation {
                    guard let a = resultA, let b = resultB else {
                        completion(nil); return
                    }
                    completion((a, b) as! A)
                }
            }
        case let ._mapped(x, transform):
            load(x) { any in
                completion(any.map(transform))
            }
        }
    }
}

let t = resource.c.zip(collections.c).map { "\($0.0.first!) — \($0.1.first!)" }


// Below is for testing ------------------------------------------

//protocol SessionProtocol {
//    func load<A>(_ r: Resource<A>, completion: @escaping (A?) -> ())
//    func onReturnQueue(_ f: @escaping () -> ())
//}
//
//extension URLSession: SessionProtocol {
//    func onReturnQueue(_ f: @escaping () -> ()) {
//        self.delegateQueue.addOperation(f)
//    }
//}
//
//struct ResourceWithResult {
//    let resource: Resource<Any>
//    let result: Any?
//    init<A>(_ resource: Resource<A>, _ result: A?) {
//        self.resource = resource.map { $0 }
//        self.result = result.map { $0 }
//    }
//}
//
//struct TestSession: SessionProtocol {
//    var expected: [ResourceWithResult] = []
//
//    func onReturnQueue(_ f: @escaping () -> ()) {
//        f()
//    }
//
//    func load<A>(_ resource: Resource<A>, completion: (A?) -> ()) {
//        for r in expected {
//            if r.resource.urlRequest == resource.urlRequest, let result = r.result as? A? {
//                completion(result)
//                return
//            }
//        }
//        completion(nil)
//    }
//}
//
//var mock = TestSession()
//mock.expected = [
//    ResourceWithResult(resource, [Episode(number: 1, title: "Test Episode")]),
//    ResourceWithResult(collections, [Collection(title: "Test Collection")])
//]
//mock.load(t) {
//    print($0)
//}
