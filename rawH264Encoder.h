//
//  rawH264Encoder.h
//  VTCompress
//
//  Created by 张颂 on 16/5/28.
//  Copyright © 2016年 张颂. All rights reserved.
//

#import <Foundation/Foundation.h>
@import AVFoundation;

@protocol rawH264EncoderDelegate <NSObject>

- (void)gotSpsPps:(NSData*)sps pps:(NSData*)pps;
- (void)gotEncodedData:(NSData*)data isKeyFrame:(BOOL)isKeyFrame;
- (void)gotCompressedSampleBuffer:(CMSampleBufferRef) sampleBuffer;

@end

@interface rawH264Encoder : NSObject

- (instancetype)initWithWidth:(int32_t)width height:(int32_t)height;
- (void)encode:(CMSampleBufferRef)sampleBuffer;
- (void)finish;

@property (weak, nonatomic) id<rawH264EncoderDelegate> delegate;

@end
