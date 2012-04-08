#!/usr/bin/perl
#
# A rewrite of EWC Proxy.
#

use strict;
use warnings;

use Digest::SHA1 qw( sha1_hex );
use Fcntl qw( :DEFAULT );

use Socket;

my $ewc_ip = "50.19.227.38";
#my $ewc_ip = "74.208.66.169";

my $ewc_magic_constant = "5487357816";

my $sinner = sockaddr_in(7000, INADDR_ANY);
my $csi = sockaddr_in(7000, inet_aton($ewc_ip));

my %ctcp_replies = (
	"VERSION" => "EveryWhereChat Rambler 2.1.761 [Linux 3.0.0-12-generic]",
	"CLIENTDATA" => "URL: http://everywherechat.com/everywherechat.swf | OS: Linux 3.0.0-12-generic | Browser: Netscape 5.0 (X11) | Flash: LNX 11,0,1,152 | EyjRkhgw4XeHzcIKBTwvluhCCuhAgUqtBhtv7xQNBKlSldvIf0LL8oWhSALWcYCqZUZbc94245QsVwxT0WMMCykHZ8GgoFI9LoUgRYvtH1ueEY00KSMa2KeCiyDPKGgH | [secret] | [secret_material] | rambler | [nick]"
);


sub irc_tokenize {
	my ($line, undef) = @_; 
	
	my $dline = trim($line);
	my @stokens = split / /, $dline; 
	my @tokens = (); 
	
	my $token = "";
	my $ttoken = "";
	my $trailing = 0;
TOKENIZE:
	for (my $i = 0; $i < scalar(@stokens); $i++) {
		$token = $stokens[$i]; 
		if (substr($token, 0, 1) eq ":") {
			if ($i == 0) {
				$token = substr($token, 1); 
				push @tokens, $token; 
				next TOKENIZE;
			}
			$trailing = 1; 
			$ttoken .= " $token" if ($ttoken ne "" && $trailing);
			$ttoken = substr($token, 1) if ($ttoken eq "");
		} else {
			push @tokens, $token if (!$trailing);
			$ttoken .= " $token" if ($trailing); 
		}
	}
	push @tokens, $ttoken if ($trailing && $ttoken ne ""); 
	
	return @tokens; 
}

sub irc_src {
	my ($src_token, undef) = @_; 
	
	my $exclamation = index($src_token, "!");
	my $at = index($src_token, "@"); 
	
	my ($nick, $user, $host) = ("", "", "");
	
	if ($exclamation < 0) { return ($src_token, "", ""); }
	else {
		$nick = substr($src_token, 0, $exclamation); 
		
		if ($at < 0) { return ($nick, "", ""); }
		else {
			$user = substr($src_token, $exclamation+1, ($at - ($exclamation+1)));
			$host = substr($src_token, $at+1);
			return ($nick, $user, $host); 
		}
	}
}
sub trim {
	my ($str, undef) = @_; 
	
	return undef if !defined($str);
	
	my $old_sep = $/;
	
	my $n_str = $str;
	$n_str =~ s/(\s|\r|\n)*(.*)(\s|\r|\n)*/$2/gs;
	return $n_str;
}

	
socket(my $server_socket, PF_INET, SOCK_STREAM, getprotobyname('tcp'));
setsockopt($server_socket, SOL_SOCKET, SO_REUSEADDR, pack("l", 1));
bind($server_socket, $sinner) or die "Couldn't bind!\n";
listen($server_socket, SOMAXCONN) or die "Couldn't listen!\n";

my $flags = fcntl($server_socket, F_GETFL, 0);
fcntl($server_socket, F_SETFL, $flags|O_NONBLOCK);

my @pairs = (); 

while (1) {
	my $readers = '';
	my $writers = '';
	my @purgelist = ();
	my $damn = "";
	vec($readers, fileno($server_socket), 1) = 1; 
	if (scalar(@pairs)) {
		for my $pair (@pairs) {
			vec($readers, fileno($pair->{'cs'}), 1) = 1;
			vec($writers, fileno($pair->{'cs'}), 1) = 1 if ($pair->{'cw'} ne '');
			
			vec($readers, fileno($pair->{'ss'}), 1) = 1;
			vec($writers, fileno($pair->{'ss'}), 1) = 1 if ($pair->{'sw'} ne '');
		}
	}
	
	select($readers, $writers, $damn, undef);
	
	for (my $i = 0; $i < scalar(@pairs); $i++) {
		# clients+reading, servers+writing, servers+reading, clients+writing
		# clients+reading
		my $pair = $pairs[$i]; 
		if (defined(fileno($pair->{'cs'})) && vec($readers, fileno($pair->{'cs'}), 1)) {
			my $tmpbuf = '';
			my $read = sysread($pair->{'cs'}, $tmpbuf, 512);
			if ($read == 512) {
				while (defined($read) && $read > 0) {
					$pair->{'cr'} .= $tmpbuf;
					$read = sysread($pair->{'cs'}, $tmpbuf, 512);
					my $dr_or_er = (defined($read) && $read >= 0) ? 0 : 1; 
					$tmpbuf = "" if ($dr_or_er); 
				}
			} elsif ($read == 0) {
				# End Of Socket
				close($pair->{'cs'});
				close($pair->{'ss'});
				push @purgelist, $i;
			}
						
			$pair->{'cr'} .= $tmpbuf;
			
			while ((my $eoli = index($pair->{'cr'}, "\n")) >= 0) {
				my $line = substr($pair->{'cr'}, 0, $eoli);
				if ($eoli == length($line)-1) {
					$pair->{'cr'} = "";
				} else {
					$pair->{'cr'} = substr($pair->{'cr'}, $eoli+1);
				}
				
				if (substr($line, $eoli-1, 1) eq "\r") { $line = substr($line, 0, $eoli-1); }
				
				my @tokens = irc_tokenize($line);
				
				# Process cmd FROM CLIENT here
				if (uc($tokens[0]) eq "NICK") {
					# pass through
					#print "Nick " . trim($tokens[1]) . "\n";
					$pair->{'sw'} .= "NICK " . trim($tokens[1]) . "\r\n";
					$pair->{'nick'} = trim($tokens[1]);
				} elsif (uc($tokens[0]) eq "USER") {
					if ($tokens[1] eq "ewcflash" && $tokens[2] eq "rambler") {
						print "Assuming your EWC client is EWC flash; WILL PASS THROUGH EVERYTHING (and get some information)...\n";
						$pair->{'cw'} .= ":ewcproxy!ewcproxy\@admin.everywherechat.com PRIVMSG " . $pair->{'nick'} . " :\001VERSION\001\r\n";
						$pair->{'cw'} .= ":ewcproxy!ewcproxy\@admin.everywherechat.com PRIVMSG " . $pair->{'nick'} . " :\001CLIENTDATA\001\r\n";
						print "Requesting from client: " . $pair->{'cw'} . "\n";
						$pair->{'is_real'} = 1;
						$pair->{'sw'} .= $line . "\r\n"; 
					} else {
						# nope
						$pair->{'sw'} .= "USER ewcflash rambler irc.everywherechat.com :EveryWhereChat Rambler 2.1.761\r\n"; 
					}
				} elsif (uc($tokens[0]) eq "NOTICE") {
					# Is it a CTCP reply? 
					my $msg = $tokens[2];
					if (substr($msg,0,1) eq "\001") {
						# Yes -> shoot down unless real (intercept if real)
						if (uc(substr($msg,0,8)) eq "\001VERSION" && $pair->{'is_real'}) {
							print "Version provided by real client is: " . substr($msg,9) . "\n";
							$pair->{'got_version'} = 1;
						} elsif (uc(substr($msg,0,11)) eq "\001CLIENTDATA" && $pair->{'is_real'}) {
							print "CLIENTINFO provided by real client is: " . substr($msg,12) . "\n";
							$pair->{'got_version'} = 1; 
						}
						
						$pair->{'sw'} .= $line if ($pair->{'is_real'} && $tokens[1] ne "ewcproxy"); # AND ONLY IF THIS IS TRUE!
					} else {
						# Not CTCP... don't give a fuck
						$pair->{'sw'} .= trim($line) . "\r\n";
					}
				} elsif (uc($tokens[0]) eq "PONG" || uc($tokens[0]) eq "PING") {
					# no. no no no no no. Not unless the thing is real. Do NOT allow the client to fuck us here!
					$pair->{'sw'} .= $line if ($pair->{'is_real'});
					if (uc($tokens[0]) eq "PING") {
						# cheat with X-Chat, which uses PING/PONG as a way to measure lag
						$pair->{'cw'} .= ":ewcproxy.fxchip.net PONG ewcproxy.fxchip.net :" . $tokens[1] . "\r\n"; 
					}
				} else {
					# we don't really care... pass it along, maybe warn the user. 
					$pair->{'sw'} .= trim($line) . "\r\n"; 
				}
			}
		}
		
		# servers+writing
		if (defined(fileno($pair->{'ss'})) && vec($writers, fileno($pair->{'ss'}), 1)) {
			my $bytes_written = syswrite($pair->{'ss'}, $pair->{'sw'}, length($pair->{'sw'}));
			if ($bytes_written < length($pair->{'sw'})) {
				$pair->{'sw'} = substr($pair->{'sw'}, $bytes_written);
			} else { $pair->{'sw'} = ""; }
		}
		
		# servers+reading
		if (defined(fileno($pair->{'ss'})) && vec($readers, fileno($pair->{'ss'}), 1)) {
			my $tmpbuf = "";
			my $read = sysread($pair->{'ss'}, $tmpbuf, 512);
			if ($read == 512) {
				while (defined($read) && $read > 0) {
					$pair->{'sr'} .= $tmpbuf;
					$read = sysread($pair->{'ss'}, $tmpbuf, 512);
					my $dr_or_er = (defined($read) && $read >= 1) ? 0 : 1;
					$tmpbuf = "" if ($dr_or_er); 
				}
			} elsif ($read == 0) {
				close($pair->{'cs'});
				close($pair->{'ss'});
				push @purgelist, $i;
			}
						
			$pair->{'sr'} .= $tmpbuf; 
			
			while ((my $eoli = index($pair->{'sr'}, "\n")) >= 0) {
				my $line = substr($pair->{'sr'}, 0, $eoli);
				if ($eoli == length($pair->{'sr'})-1) { $pair->{'sr'} = ""; }
				else { $pair->{'sr'} = substr($pair->{'sr'}, $eoli+1); }
				
				if (substr($line, $eoli-1, 1) eq "\r") { $line = substr($line, 0, $eoli-1); }
				
				my @tokens = irc_tokenize($line);
				
				# Process cmd FROM SERVER here
				if (uc($tokens[1]) eq "PING" || uc($tokens[0]) eq "PING") { # Fucking silly, no server sends just the PING. :(
					if ($pair->{'secret'} eq "") {
						# Generate a 'secret'. a.k.a. j is a fucking dumbass
						my $which_next_token_i = (uc($tokens[0]) eq "PING") ? 1 : 2; 
						$pair->{'secret_material'} = $tokens[$which_next_token_i];
						$pair->{'secret'} = sha1_hex("rambler" . $tokens[$which_next_token_i] . $pair->{'nick'} . $ewc_magic_constant);
					}
					$pair->{'sw'} .= "PONG " . $pair->{'secret'} . "\r\n";
					#print "SEND PONG " . $pair->{'secret'} . "\n";
					print "Authenticating to the server...\n";
				} elsif (uc($tokens[1]) eq "PRIVMSG") {
					my $msg = $tokens[3];
					my ($nick, $user, $host) = irc_src($tokens[0]); 
					# Is it CTCP?
					if (substr($msg,0,1) eq "\001") {
						# yes -> blackhole or fake if we're faking, passthru if real
						if (!$pair->{'is_real'}) {
							if (uc(substr($msg, 0, 8)) eq "\001VERSION") {
								# Fake our VERSION
								$pair->{'sw'} .= "NOTICE " . $nick . " :\001VERSION " . $ctcp_replies{'VERSION'} . "\001\r\n"; 
							} elsif (uc(substr($msg, 0, 11)) eq "\001CLIENTDATA") {
								# Fake our CLIENTINFO
								my $ci = $ctcp_replies{'CLIENTDATA'};
								my $secret = ($pair->{'secret'} eq "" ? "null" : $pair->{'secret'});
								my $secret_material = ($pair->{'secret_material'} eq "" ? "null" : $pair->{'secret_material'});
								$ci =~ s/\[nick\]/$pair->{'nick'}/g;
								$ci =~ s/\[secret\]/$secret/g;
								$ci =~ s/\[secret_material\]/$secret_material/g;
								
								$pair->{'sw'} .= "NOTICE " . $nick . " :\001CLIENTDATA " . $ci . "\001\r\n"; 
							} elsif (uc(substr($msg, 0, 12)) eq "\001BLOCKCLIENT") {
								print "WARNING: CTCP BLOCKCLIENT RECEIVED: You are VERY likely to be banned at this point!\n"; 
								print "Due to this knowledge, we have taken the liberty of thumbing our nose at the admin!\n"; 
								$pair->{'sw'} .= "NOTICE " . $nick . " :\001BLOCKCLIENT Quack-a-doodle-moo!\001\r\n"; 
							}
						} else { 
							$pair->{'cw'} .= trim($line) . "\r\n"; 
						}
					} else {
						# no -> LOOK AT ALL THE FUCKS I GIVE
						$pair->{'cw'} .= trim($line) . "\r\n";
					}
				} else {
					# LOOK AT ALL THE FUCKS I GIVE
					$pair->{'cw'} .= trim($line) . "\r\n"; 
					#print "write to client: " . $line . "\n";
					#print "current buffer: " . $pair->{'cw'} . "\n";
				}
			}
		}
		
		# clients+writing
		if (defined(fileno($pair->{'cs'})) && vec($writers, fileno($pair->{'cs'}), 1)) {
			my $bytes_written = syswrite($pair->{'cs'}, $pair->{'cw'}, length($pair->{'cw'}));
			if ($bytes_written < length($pair->{'cw'})) {
				$pair->{'cw'} = substr($pair->{'cw'}, $bytes_written);
			} else { $pair->{'cw'} = ""; }
		}
	}
				
	if (vec($readers, fileno($server_socket), 1)) {
		my $new_pair = {};
		my $old_fd = undef;
		accept($new_pair->{'cs'}, $server_socket);
		fcntl($new_pair->{'cs'}, F_SETFL, $flags|O_NONBLOCK);
		$old_fd = select $new_pair->{'cs'}; $|=1; select $old_fd;
		
		socket($new_pair->{'ss'}, PF_INET, SOCK_STREAM, getprotobyname('tcp'));
		connect($new_pair->{'ss'}, $csi);
		fcntl($new_pair->{'ss'}, F_SETFL, $flags|O_NONBLOCK);
		$old_fd = select $new_pair->{'ss'}; $|=1; select $old_fd;
		
		$new_pair->{'is_real'} = 0;
		$new_pair->{'secret'} = "";
		$new_pair->{'secret_material'} = "";
		
		$new_pair->{'cr'} = ""; 
		$new_pair->{'cw'} = "";
		$new_pair->{'sr'} = "";
		$new_pair->{'sw'} = "";
		
		$new_pair->{'got_version'} = 0;
				
		push @pairs, $new_pair; 
	}
	
	my $purge_offset = 0; 
	for my $purge_idx (@purgelist) {
		splice @pairs, $purge_idx-$purge_offset, 1;
		$purge_offset++; 
	}
}
		
