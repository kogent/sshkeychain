#import "SSHKeychain.h"
#import "PreferenceController.h"
#import "TokenController.h"

#import "SSHKey.h"
#import "SSHTool.h"
#import "SSHAgent.h"

#include <unistd.h>

SSHKeychain *currentKeychain;

@implementation SSHKeychain

/* Return the global keychain, if set. */
+ (id)currentKeychain
{
	if (! currentKeychain)
		currentKeychain = [[self keychainWithPaths:[[NSUserDefaults standardUserDefaults] arrayForKey:@"Keys"]] retain];

	return currentKeychain;
}

/* Construct a SSHKeychain object with thePaths as SSHKey's. */
+ (id)keychainWithPaths:(NSArray *)paths
{
	return [[[self alloc] initWithPaths:paths] autorelease];
}

- (id)initWithPaths:(NSArray *)paths
{
	if (!(self = [super init]))
		return nil;

	keychainLock = [[NSLock alloc] init];
	addingKeysLock = [[NSLock alloc] init];
	
	[self resetToKeysWithPaths:paths];
	
	return self;
}

- (void)dealloc
{
	currentKeychain = nil;

	[keychainLock lock];
	[keychain release];
	[keychainLock unlock];

	[keychainLock release];
	[addingKeysLock release];
	[agentSocketPath release];
	
	[super dealloc];
}

- (void) setKeychain:(NSMutableArray *)newKeychain
{
	[keychainLock lock];
	NSMutableArray *oldKeychain = keychain;
	keychain = [newKeychain retain];
	[oldKeychain release];
	[keychainLock unlock];
}

/* Reset the keychain, and add thePaths as keys. */
- (void)resetToKeysWithPaths:(NSArray *)paths
{
	NSMutableArray *newKeychain = [NSMutableArray array];

	NSEnumerator *e = [paths objectEnumerator];
	NSString *path;
	while (path = [e nextObject])
	{
		/* If the key is valid, add it to the keychain array. */
		SSHKey *theKey = [SSHKey keyWithPath:path];
		if (theKey)
			[newKeychain addObject:theKey];
	}

	[self setKeychain:newKeychain];
}

/* Set the socket path we should use for ssh-add. */
- (void)setAgentSocketPath:(NSString *)path
{
	NSString *oldAgentSocketPath = agentSocketPath;
	agentSocketPath = [path copy];
	[oldAgentSocketPath release];
}

/* Tell the receiver if we're adding keys. */
- (BOOL)addingKeys
{
	[addingKeysLock lock];
	BOOL returnBool = addingKeys;
	[addingKeysLock unlock];

	return returnBool;
}

- (void) setAddingKeys:(BOOL)adding
{
	[addingKeysLock lock];
	addingKeys = adding;
	[addingKeysLock unlock];
}

/* Returns the SSHKey at Index nr. */
- (SSHKey *)keyAtIndex:(int)nr
{
	[keychainLock lock];
	SSHKey *returnKey = nil;
	if (nr >= 0 && nr < [keychain count])
		returnKey = [keychain objectAtIndex:nr];
	[keychainLock unlock];
	
	return returnKey;
}

/* Remove key from keychain. */
- (BOOL)removeKeyAtIndex:(int)nr
{
	[keychainLock lock];
	[keychain removeObjectAtIndex:nr];
	[keychainLock unlock];

	[[NSNotificationCenter defaultCenter]  postNotificationName:@"KeychainChanged" object:nil];

	return YES;
}

/* Add SSHKey object to keychain. */
- (BOOL)addKey:(SSHKey *)key
{
	[keychainLock lock];
	[keychain addObject:key];
	[keychainLock unlock];

	[[NSNotificationCenter defaultCenter]  postNotificationName:@"KeychainChanged" object:nil];

	return YES;
}

/* Construct SSHKey object and add it to the keychain. */
- (BOOL)addKeyWithPath:(NSString *)path
{
	SSHKey *key = [SSHKey keyWithPath:path];
	if (!key)
		return NO;

	return [self addKey:key];
}

/* Return an array of paths for all keys on the keychain. */
- (NSArray *)arrayOfPaths
{
	NSMutableArray *paths = [NSMutableArray array];
	
	[keychainLock lock];
	NSEnumerator *e = [keychain objectEnumerator];
	SSHKey *key;
	while (key = [e nextObject])
		[paths addObject:[key path]];
	[keychainLock unlock];

	return paths;
}

/* Return the number of keys on the chain. */
- (int)count
{
	[keychainLock lock];
	int returnInt = [keychain count];
	[keychainLock unlock];

	return returnInt;
}

/* Wrapper for addKeysToAgentWithInteraction:YES. */
- (BOOL)addKeysToAgent
{
	return [self addKeysToAgentWithInteraction:YES];
}

/* Add all keys from the keychain to the ssh-agent. */
- (BOOL)addKeysToAgentWithInteraction:(BOOL)interaction
{
	if ([self addingKeys])
		return YES;

	if (![[SSHAgent currentAgent] isRunning])
		return NO;
	
	NSMutableArray *paths = [NSMutableArray array];
	NSEnumerator *e = [[self arrayOfPaths] objectEnumerator];
	NSString *path;

	while (path = [e nextObject])
	{
		if ([[NSFileManager defaultManager] isReadableFileAtPath:path])
			[paths addObject:path];
	}
		
	if ([paths count] < 1)
		return NO;

	[self setAddingKeys:YES];

	// Add all keys separately since they need different tokens	
	e = [paths objectEnumerator];
	while (path = [e nextObject]) 
	{
		SSHTool *theTool = [SSHTool toolWithName:@"ssh-add"];
		[theTool setArgument:path];
		
		/* Set the SSH_ASKPASS + DISPLAY environment variables, so the tool can ask for a passphrase. */
		[theTool setEnvironmentVariable:@"SSH_ASKPASS" withValue:
			[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"PassphraseRequester"]];
			
		[theTool setEnvironmentVariable:@"DISPLAY" withValue:@":0"];
		
		/* If we want user interaction, we set the environment variable so PassphraseRequester knows this. */
		if (interaction)
			[theTool setEnvironmentVariable:@"INTERACTION" withValue:@"1"];
		
		/* Set the SSH_AUTH_SOCK environment variable so the tool can talk to the real agent. */
		[theTool setEnvironmentVariable:@"SSH_AUTH_SOCK" withValue:agentSocketPath];
		
		/* Set the token and run. */
		if(![[TokenController sharedController] generateNewTokenForTool:theTool] || ![theTool launchAndWait])
		{
			[self setAddingKeys:NO];
			return NO;
		}
	}
	
	[[NSNotificationCenter defaultCenter]  postNotificationName:@"AgentFilled" object:nil];
	
	[self setAddingKeys:NO];
	return YES;
}

/* Remove all keys from the ssh-agent. */
- (BOOL)removeKeysFromAgent
{
	SSHTool *theTool = [SSHTool toolWithName:@"ssh-add"];

	if (![[SSHAgent currentAgent] isRunning])
		return NO;

	[theTool setArgument:@"-D"];
	[theTool setEnvironmentVariable:@"SSH_AUTH_SOCK" withValue:agentSocketPath];

	[theTool launchAndWait];

	[[NSNotificationCenter defaultCenter]  postNotificationName:@"AgentEmptied" object:nil];

	return YES;
}

@end
