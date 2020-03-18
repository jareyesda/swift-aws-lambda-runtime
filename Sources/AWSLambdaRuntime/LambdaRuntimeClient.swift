//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftAWSLambdaRuntime open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftAWSLambdaRuntime project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftAWSLambdaRuntime project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import class Foundation.JSONEncoder
import Logging
import NIO
import NIOHTTP1

/// An HTTP based client for AWS Runtime Engine. This encapsulates the RESTful methods exposed by the Runtime Engine:
/// * /runtime/invocation/next
/// * /runtime/invocation/response
/// * /runtime/invocation/error
/// * /runtime/init/error
extension Lambda {
    internal struct RuntimeClient {
        private let eventLoop: EventLoop
        private let allocator = ByteBufferAllocator()
        private let httpClient: HTTPClient

        init(eventLoop: EventLoop, configuration: Configuration.RuntimeEngine) {
            self.eventLoop = eventLoop
            self.httpClient = HTTPClient(eventLoop: eventLoop, configuration: configuration)
        }

        /// Requests work from the Runtime Engine.
        func requestWork(logger: Logger) -> EventLoopFuture<(Invocation, ByteBuffer)> {
            let url = Consts.invocationURLPrefix + Consts.requestWorkURLSuffix
            logger.debug("requesting work from lambda runtime engine using \(url)")
            return self.httpClient.get(url: url).flatMapThrowing { response in
                guard response.status == .ok else {
                    throw RuntimeError.badStatusCode(response.status)
                }
                let invocation = try Invocation(headers: response.headers)
                guard let payload = response.body else {
                    throw RuntimeError.noBody
                }
                return (invocation, payload)
            }.flatMapErrorThrowing { error in
                switch error {
                case HTTPClient.Errors.timeout:
                    throw RuntimeError.upstreamError("timeout")
                case HTTPClient.Errors.connectionResetByPeer:
                    throw RuntimeError.upstreamError("connectionResetByPeer")
                default:
                    throw error
                }
            }
        }

        /// Reports a result to the Runtime Engine.
        func reportResults(logger: Logger, invocation: Invocation, result: Result<ByteBuffer?, Error>) -> EventLoopFuture<Void> {
            var url = Consts.invocationURLPrefix + "/" + invocation.requestId
            var body: ByteBuffer?
            switch result {
            case .success(let buffer):
                url += Consts.postResponseURLSuffix
                body = buffer
            case .failure(let error):
                url += Consts.postErrorURLSuffix
                let error = ErrorResponse(errorType: Consts.functionError, errorMessage: "\(error)")
                switch error.toJson() {
                case .failure(let jsonError):
                    return self.eventLoop.makeFailedFuture(RuntimeError.json(jsonError))
                case .success(let json):
                    body = self.allocator.buffer(capacity: json.utf8.count)
                    body!.writeString(json)
                }
            }
            logger.debug("reporting results to lambda runtime engine using \(url)")
            return self.httpClient.post(url: url, body: body).flatMapThrowing { response in
                guard response.status == .accepted else {
                    throw RuntimeError.badStatusCode(response.status)
                }
                return ()
            }.flatMapErrorThrowing { error in
                switch error {
                case HTTPClient.Errors.timeout:
                    throw RuntimeError.upstreamError("timeout")
                case HTTPClient.Errors.connectionResetByPeer:
                    throw RuntimeError.upstreamError("connectionResetByPeer")
                default:
                    throw error
                }
            }
        }

        /// Reports an initialization error to the Runtime Engine.
        func reportInitializationError(logger: Logger, error: Error) -> EventLoopFuture<Void> {
            let url = Consts.postInitErrorURL
            let errorResponse = ErrorResponse(errorType: Consts.initializationError, errorMessage: "\(error)")
            var body: ByteBuffer
            switch errorResponse.toJson() {
            case .failure(let jsonError):
                return self.eventLoop.makeFailedFuture(RuntimeError.json(jsonError))
            case .success(let json):
                body = self.allocator.buffer(capacity: json.utf8.count)
                body.writeString(json)
                logger.warning("reporting initialization error to lambda runtime engine using \(url)")
                return self.httpClient.post(url: url, body: body).flatMapThrowing { response in
                    guard response.status == .accepted else {
                        throw RuntimeError.badStatusCode(response.status)
                    }
                    return ()
                }.flatMapErrorThrowing { error in
                    switch error {
                    case HTTPClient.Errors.timeout:
                        throw RuntimeError.upstreamError("timeout")
                    case HTTPClient.Errors.connectionResetByPeer:
                        throw RuntimeError.upstreamError("connectionResetByPeer")
                    default:
                        throw error
                    }
                }
            }
        }
    }
}

internal extension Lambda {
    enum RuntimeError: Error {
        case badStatusCode(HTTPResponseStatus)
        case upstreamError(String)
        case invocationMissingHeader(String)
        case noBody
        case json(Error)
    }
}

internal struct ErrorResponse: Codable {
    var errorType: String
    var errorMessage: String
}

private extension ErrorResponse {
    func toJson() -> Result<String, Error> {
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(self)
            return .success(String(data: data, encoding: .utf8) ?? "unknown error")
        } catch {
            return .failure(error)
        }
    }
}

extension Lambda {
    internal struct Invocation {
        let requestId: String
        let deadlineInMillisSinceEpoch: Int64
        let invokedFunctionArn: String
        let traceId: String
        let clientContext: String?
        let cognitoIdentity: String?

        init(headers: HTTPHeaders) throws {
            guard let requestId = headers.first(name: AmazonHeaders.requestID), !requestId.isEmpty else {
                throw RuntimeError.invocationMissingHeader(AmazonHeaders.requestID)
            }

            guard let deadline = headers.first(name: AmazonHeaders.deadline),
                let unixTimeInMilliseconds = Int64(deadline) else {
                throw RuntimeError.invocationMissingHeader(AmazonHeaders.deadline)
            }

            guard let invokedFunctionArn = headers.first(name: AmazonHeaders.invokedFunctionARN) else {
                throw RuntimeError.invocationMissingHeader(AmazonHeaders.invokedFunctionARN)
            }

            guard let traceId = headers.first(name: AmazonHeaders.traceID) else {
                throw RuntimeError.invocationMissingHeader(AmazonHeaders.traceID)
            }

            self.requestId = requestId
            self.deadlineInMillisSinceEpoch = unixTimeInMilliseconds
            self.invokedFunctionArn = invokedFunctionArn
            self.traceId = traceId
            self.clientContext = headers["Lambda-Runtime-Client-Context"].first
            self.cognitoIdentity = headers["Lambda-Runtime-Cognito-Identity"].first
        }
    }
}