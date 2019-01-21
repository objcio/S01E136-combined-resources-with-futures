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

let episodes = Resource<[Episode]>(get: URL(string: "https://talk.objc.io/episodes.json")!)
let collections = Resource<[Collection]>(get: URL(string: "https://talk.objc.io/collections.json")!)

// We have everything up until here -------------------------------------------------

struct SessionPromise<A> {
    let run: (URLSession, @escaping (A) -> ()) -> ()
    init(_ run: @escaping (URLSession, @escaping (A) -> ()) -> ()) {
        self.run = run
    }
    
    func map<B>(_ f: @escaping (A) -> B) -> SessionPromise<B> {
        return SessionPromise<B> { sess, cb in
            self.run(sess) { a in
                cb(f(a))
            }
        }
    }
    
    func flatMap<B>(_ f: @escaping (A) -> SessionPromise<B>) -> SessionPromise<B> {
        return SessionPromise<B> { sess, cb in
            self.run(sess) { a in
                let p = f(a)
                p.run(sess, cb)
            }
        }
    }
    
    func zip<B>(_ other: SessionPromise<B>) -> SessionPromise<(A,B)> {
        return SessionPromise<(A,B)> { sess, cb in
            var resultA: A?
            var resultB: B?
            let group = DispatchGroup()
            group.enter()
            self.run(sess) { a in
                resultA = a
                group.leave()
            }
            group.enter()
            other.run(sess) { b in
                resultB = b
                group.leave()
            }
            group.notify(queue: .global()) {
                cb((resultA!, resultB!))
            }
        }
    }
}

extension Resource {
    var promise: SessionPromise<A?> {
        return SessionPromise { sess, cb in
            sess.load(self, completion: cb)
        }
    }
}

let combined = episodes.promise.zip(collections.promise).map { "\($0.0!.first!) — \($0.1!.first!)" }
combined.run(URLSession.shared) {
    print($0)
}


// Below is for testing -----------------------------------------------

//protocol SessionProtocol {
//    func load<A>(_ r: Resource<A>, completion: @escaping (A?) -> ())
//    func load<A>(_ r: Resource<A>) -> Promise<A?>
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
//
//    func load<A>(_ resource: Resource<A>) -> Promise<A?> {
//        for r in expected {
//            if r.resource.urlRequest == resource.urlRequest, let result = r.result as? A? {
//                return Promise { $0(result) }
//            }
//        }
//        return Promise { $0(nil) }
//    }
//}
//
//var mock = TestSession()
//mock.expected = [
//    ResourceWithResult(episodes, [Episode(number: 1, title: "Test Episode")]),
//    ResourceWithResult(collections, [Collection(title: "Test Collection")])
//]
//
//sharedSession = mock

