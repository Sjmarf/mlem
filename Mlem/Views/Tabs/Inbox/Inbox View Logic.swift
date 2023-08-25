//
//  Inbox Feed View Logic.swift
//  Mlem
//
//  Created by Eric Andrews on 2023-06-26.
//

import Foundation

extension InboxView {
    // MARK: Tracker Updates
    
    func refreshFeed(clearBeforeFetch: Bool = false) async {
        defer { isLoading = false }
        do {
            isLoading = true
            
            if clearBeforeFetch {
                allItems = .init()
            }
            
            // load feeds in parallel
            async let repliesRefresh: () = refreshRepliesTracker()
            async let mentionsRefresh: () = refreshMentionsTracker()
            async let messagesRefresh: () = refreshMessagesTracker()
            async let unreadRefresh: () = unreadTracker.update(with: personRepository.getUnreadCounts())
            
            _ = try await [repliesRefresh, mentionsRefresh, messagesRefresh, unreadRefresh]
            
            errorOccurred = false
            
            if curTab == .all {
                aggregateAllTrackers()
            }
        } catch APIClientError.networking {
            errorOccurred = true
            errorMessage = "Network error occurred, check your internet and retry"
        } catch let APIClientError.response(message, _) {
            print(message)
            errorOccurred = true
            errorMessage = "API error occurred, try refreshing"
        } catch APIClientError.cancelled {
            print("Failed while loading feed (request cancelled)")
            errorOccurred = true
            errorMessage = "Request was cancelled, try refreshing"
        } catch APIClientError.invalidSession {
            errorHandler.handle(APIClientError.invalidSession)
        } catch let message {
            print(message)
            errorOccurred = true
            errorMessage = "A decoding error occurred, try refreshing."
        }
    }
    
    func refreshRepliesTracker() async throws {
        if curTab == .all || curTab == .replies {
            try await repliesTracker.refresh(account: appState.currentActiveAccount, unreadOnly: shouldFilterRead)
        }
    }
    
    func refreshMentionsTracker() async throws {
        if curTab == .all || curTab == .mentions {
            try await mentionsTracker.refresh(account: appState.currentActiveAccount, unreadOnly: shouldFilterRead)
        }
    }
    
    func refreshMessagesTracker() async throws {
        if curTab == .all || curTab == .messages {
            try await messagesTracker.refresh(account: appState.currentActiveAccount, unreadOnly: shouldFilterRead)
        }
    }
    
    func filterUser(userId: Int) {
        repliesTracker.filter { reply in
            reply.creator.id != userId
        }
        mentionsTracker.filter { mention in
            mention.creator.id != userId
        }
        messagesTracker.filter { message in
            message.creator.id != userId
        }
        
        aggregateAllTrackers()
    }
    
    func filterRead() async {
        shouldFilterRead.toggle()
        await refreshFeed(clearBeforeFetch: true)
    }
    
    func markAllAsRead() async {
        do {
            try await personRepository.markAllAsRead()
            await refreshFeed()
        } catch {
            errorHandler.handle(error)
        }
    }
    
    func loadTrackerPage(tracker: InboxTracker) async {
        do {
            try await tracker.loadNextPage(account: appState.currentActiveAccount, unreadOnly: shouldFilterRead)
            aggregateAllTrackers()
            // TODO: make that call above return the new items and do a nice neat merge sort that doesn't re-merge the whole damn array
        } catch let message {
            print(message)
        }
    }
    
    func aggregateAllTrackers() {
        let mentions = mentionsTracker.items.map { item in
            InboxItem(
                published: item.personMention.published,
                baseId: item.id,
                read: item.personMention.read,
                type: .mention(item)
            )
        }
        
        let messages = messagesTracker.items.map { item in
            InboxItem(
                published: item.privateMessage.published,
                baseId: item.id,
                read: item.privateMessage.read,
                type: .message(item)
            )
        }
        
        let replies = repliesTracker.items.map { item in
            InboxItem(
                published: item.commentReply.published,
                baseId: item.id,
                read: item.commentReply.read,
                type: .reply(item)
            )
        }
        
        allItems = merge(arr1: mentions, arr2: messages, compare: wasPostedAfter)
        allItems = merge(arr1: allItems, arr2: replies, compare: wasPostedAfter)
        isLoading = false
    }
    
    // MARK: - Replies
    
    func voteOnCommentReply(commentReply: APICommentReplyView, inputOp: ScoringOperation) {
        Task(priority: .userInitiated) {
            let operation = commentReply.myVote == inputOp ? ScoringOperation.resetVote : inputOp
            do {
                let updatedReply = try await commentRepository.voteOnCommentReply(commentReply, vote: operation)
                repliesTracker.update(with: updatedReply)
                if curTab == .all {
                    // TODO: more granular/less expensive merge options
                    aggregateAllTrackers()
                }
            } catch {
                errorHandler.handle(error)
            }
        }
    }
    
    func toggleCommentReplyRead(commentReplyView: APICommentReplyView) {
        hapticManager.play(haptic: .gentleSuccess, priority: .low)
        Task(priority: .userInitiated) {
            do {
                let response = try await commentRepository.markCommentReadStatus(
                    id: commentReplyView.id,
                    isRead: !commentReplyView.commentReply.read
                )
                
                repliesTracker.update(with: response.commentReplyView)
                
                // TODO: should this be done _before_ the call, and then reverted in the `catch` if required?
                if commentReplyView.commentReply.read {
                    unreadTracker.unreadReply()
                } else {
                    unreadTracker.readReply()
                }
                
                if curTab == .all { aggregateAllTrackers() }
            } catch {
                hapticManager.play(haptic: .failure, priority: .low)
                errorHandler.handle(error)
            }
        }
    }
    
    func replyToCommentReply(commentReply: APICommentReplyView) {
        editorTracker.openEditor(with: ConcreteEditorModel(
            commentReply: commentReply,
            operation: InboxItemOperation.replyToInboxItem
        ))
    }
    
    func reportCommentReply(commentReply: APICommentReplyView) {
        editorTracker.openEditor(with: ConcreteEditorModel(
            commentReply: commentReply,
            operation: InboxItemOperation.reportInboxItem
        ))
    }
    
    // MARK: Mentions
    
    func voteOnMention(mention: APIPersonMentionView, inputOp: ScoringOperation) {
        hapticManager.play(haptic: .gentleSuccess, priority: .low)
        Task(priority: .userInitiated) {
            let operation = mention.myVote == inputOp ? ScoringOperation.resetVote : inputOp
            do {
                let updatedMention = try await commentRepository.voteOnPersonMention(mention, vote: operation)
                mentionsTracker.update(with: updatedMention)
                if curTab == .all {
                    aggregateAllTrackers()
                }
            } catch {
                hapticManager.play(haptic: .failure, priority: .high)
                errorHandler.handle(error)
            }
        }
    }
    
    func toggleMentionRead(mention: APIPersonMentionView) {
        hapticManager.play(haptic: .gentleSuccess, priority: .low)
        Task(priority: .userInitiated) {
            do {
                let updatedMention = try await apiClient.markPersonMentionAsRead(
                    mentionId: mention.personMention.id,
                    isRead: !mention.personMention.read
                )
                
                mentionsTracker.update(with: updatedMention)
                
                // TODO: should this be done before the above call and reverted in the catch if necessary?
                if mention.personMention.read {
                    unreadTracker.unreadMention()
                } else {
                    unreadTracker.readMention()
                }
                
                if curTab == .all { aggregateAllTrackers() }
            } catch {
                hapticManager.play(haptic: .failure, priority: .high)
                errorHandler.handle(error)
            }
        }
    }
    
    func reportMention(mention: APIPersonMentionView) {
        editorTracker.openEditor(with: ConcreteEditorModel(
            mention: mention,
            operation: InboxItemOperation.reportInboxItem
        ))
    }
    
    func replyToMention(mention: APIPersonMentionView) {
        editorTracker.openEditor(with: ConcreteEditorModel(
            mention: mention,
            operation: InboxItemOperation.replyToInboxItem
        ))
    }
    
    // MARK: Messages
    
    func toggleMessageRead(message: APIPrivateMessageView) {
        hapticManager.play(haptic: .gentleSuccess, priority: .low)
        Task(priority: .userInitiated) {
            do {
                let updatedMessage = try await apiClient.markPrivateMessageRead(
                    id: message.id,
                    isRead: !message.privateMessage.read
                )
                
                messagesTracker.update(with: updatedMessage)
                
                // TODO: should this be done before the above call and reverted in the catch if necessary?
                if message.privateMessage.read {
                    unreadTracker.unreadMessage()
                } else {
                    unreadTracker.readMessage()
                }
                
                if curTab == .all { aggregateAllTrackers() }
            } catch {
                hapticManager.play(haptic: .failure, priority: .low)
                errorHandler.handle(error)
            }
        }
    }
    
    func replyToMessage(message: APIPrivateMessageView) {
        editorTracker.openEditor(with: ConcreteEditorModel(
            message: message,
            operation: InboxItemOperation.replyToInboxItem
        ))
    }
    
    func reportMessage(message: APIPrivateMessageView) {
        editorTracker.openEditor(with: ConcreteEditorModel(
            message: message,
            operation: InboxItemOperation.reportInboxItem
        ))
    }
    
    // MARK: - Helpers
    
    /**
     returns true if lhs was posted after rhs
     */
    func wasPostedAfter(lhs: InboxItem, rhs: InboxItem) -> Bool {
        lhs.published > rhs.published
    }
    
    func genMenuFunctions() -> [MenuFunction] {
        var ret: [MenuFunction] = .init()
        
        let (filterReadText, filterReadSymbol) = shouldFilterRead
            ? ("Show All", AppConstants.filterSymbolNameFill)
            : ("Show Only Unread", AppConstants.filterSymbolName)
        
        ret.append(MenuFunction(
            text: filterReadText,
            imageName: filterReadSymbol,
            destructiveActionPrompt: nil,
            enabled: true
        ) {
            Task(priority: .userInitiated) {
                await filterRead()
            }
        })
        
        ret.append(MenuFunction(
            text: "Mark All as Read",
            imageName: "envelope.open",
            destructiveActionPrompt: nil,
            enabled: true
        ) {
            Task(priority: .userInitiated) {
                await markAllAsRead()
            }
        })
        
        return ret
    }
}
