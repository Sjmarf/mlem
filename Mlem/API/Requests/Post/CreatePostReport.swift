//
//  CreatePostReport.swift
//  Mlem
//
//  Created by Jake Shirley on 7/1/23.
//

import Foundation

struct CreatePostReportRequest: APIPostRequest {

    typealias Response = CreatePostReportResponse

    let instanceURL: URL
    let path = "post/report"
    let body: Body

    // lemmy_api_common::post::CreatePostReport
    struct Body: Encodable {
        let auth: String
        let post_id: Int
        let reason: String
    }

    init(
        account: SavedAccount,
        postId: Int,
        reason: String
    ) {
        self.instanceURL = account.instanceLink
        self.body = .init(auth: account.accessToken, post_id: postId, reason: reason)
    }
}

// lemmy_api_common::person::CreatePostReportResponse
struct CreatePostReportResponse: Decodable {
    let postReportView: APIPostReportView
}
