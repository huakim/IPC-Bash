package IPC::Bash;

use 5.006;
use strict;
use warnings;

=head1 NAME

IPC::Bash - Library for interracting with bash session 

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

package IPC::Bash;
    use Moose;
    use Mutex;
    use threads;
    use Symbol;
    use MooseX::Privacy;  
    use IPC::Open3;
    use POSIX  qw(mkfifo);
    use Cwd qw(abs_path);
    use File::Temp qw(tempdir :mktemp);
    use File::Spec::Functions;  
    use File::Util::Tempdir qw(get_tempdir get_user_tempdir);
    use Bytes::Random::Secure qw(
        random_bytes_qp random_bytes_base64 random_bytes_hex
    );
    my $sk = 'F' . random_bytes_base64(3) 
             . random_bytes_hex(3);
             
    $sk =~ s/\=//g;
    $sk =~ s/\+//g;
    $sk =~ s/\///g;
    $sk =~ s/\s+//g;
    $sk .= '_';
    
    my $BASH_PROGRAM = <<'string_ending_delimiter';
skb_input="${skb_temp}/output.sock"
skb_output="${skb_temp}/input.sock"
skb_tempfile="${skb_temp}/tempfile.tmp"

skb_send(){
    echo "$1" > ${skb_input}
}

skb_recv(){
    echo $(cat ${skb_output})
}


skb_cnt() {  
    if [ "$1" ] &&         
       [ "$2" ] &&         
       [ -z "${1##*"$2"*}" ]; 
        then  return 0;                                    
        else  return 1;                                          
    fi;
}

skb_allvars(){
    typeset -p | sed -n 's/^/{ /; s/$/ ; } 2>\/dev\/null/ ; p';
    alias 2>/dev/null | sed '/^[[:space:]]*alias/! s/^/alias  /'
    typeset -f ;
}


skb_vartype(){
    skb_name="$1";

    if [ -z "${skb_name}" ]; then
        echo ''
    else
        skb_var=$(typeset -p ${skb_name} 2>/dev/null || echo '');
        if [ -z "${skb_var}" ]; then
            echo ''
        else
            skb_pat='s/\w*\s*=[^.*]\+//;s/\w*//;s/[[:space:]]//g;s/-//2g;p';
            skb_pad='s/^[^=]*=//p';
            
            skb_var="$(echo "${skb_var}" | sed -n "${skb_pat}")";
        
            while [ "\${skb_var}" '=' '-n' ]; do
                skb_name="$(typeset -p ${skb_name} 2>/dev/null | sed -n "${skb_pad}")";
                skb_var="$(typeset -p ${skb_name} 2>/dev/null | sed -n "${skb_pat}")";
            done;
            if [ -z "${skb_var}" ]; then
                eval 'echo ${'"${skb_name}"':+-}'
            else 
                echo "${skb_var}"
            fi
        fi
    fi
}

skb_getvar(){ 
    skb_varname="$1";
    if [ -z "${skb_varname}" ]; then
        printf 'undef';
    else
        skb_vartype="$(skb_vartype ${skb_varname})";
        if [ -z "${skb_vartype}" ]; then
            printf 'undef';
        else
            if skb_cnt "${skb_vartype}" 'i'; then
                skb_f='%d';
            else 
                skb_f='"%q"';
            fi;
            skb_Q='"%q" => '
            if skb_cnt "${skb_vartype}" 'a'; then
                printf '[';
                eval  '
                for skb_i in "${'"${skb_varname}"'[@]}";
                do
                    printf "${skb_f}," "${skb_i}";
                done;
                ' 
                printf ']';
            else
                if skb_cnt "${skb_vartype}" 'A'; then
                    printf '{';
                    eval '
                    for skb_i in "${!'"${skb_varname}"'[@]}"; 
                    do
                        printf "${skb_Q}" "${skb_i}";
                        printf "${skb_f}," "${'"${skb_varname}"'[${skb_i}]}";
                    done;
                    ' 
                    printf '}';
                else
                    eval 'printf "${skb_f}" $'"${skb_varname}";
                fi;
            fi;
        fi;
    fi
}


skb_sendvar(){
    skb_b="${1}"
    skb_c=$(skb_getvar "${skb_b}")
    skb_sendarg "${skb_c}"
}

skb_sendarg(){
    export skb_RETURN="${1}"
}

skb_exit(){
    echo "exit" > "${skb_tempfile}"
    exit
}

skb_fork(){
    skb_allvars
    echo skb_send '0'
    echo skb_main
}

skb_subsh(){
    $0 -c "$(skb_fork)"
}

skb_sudo(){
    sudo $0 -c "$(skb_fork)"
}

skb_sendexec(){
    skb_c=$1
    if [ "$(command -v ${skb_c})" '!=' "" ] ; then
        shift
        skb_c=$(${skb_c} "${@}")
    else 
        skb_c=""
    fi
    skb_sendarg "${skb_c}"
}

skb_getcmd(){
    skb_c="$(eval "$(echo "${@}")")"
    skb_sendarg "${skb_c}"
}

skb_main(){
    while true; do
    (
        while true; do
            skb_u="$(skb_recv)"
            eval "${skb_u}" 
            skb_send "${skb_RETURN}"
            export skb_RETURN='0'
        done
    )
    
        if [  -e "${skb_tempfile}" ]; then
            skb_TEMP="$(cat "${skb_tempfile}")"
            rm "${skb_tempfile}"
            eval "${skb_TEMP}"
        fi
        
        skb_send "${skb_RETURN}"
    done
}
unset BASH_EXECUTION_STRING 2>/dev/null
skb_main

string_ending_delimiter

  #  my $bash = $BASH_PROGRAM ;
  #  $bash =~ s/skb_//ig;
  #  print ($bash);
    
    $BASH_PROGRAM =~ s/skb_/$sk/ig;


    for (qw(temp pid input output bash thread lockcmd)){
        has $_ => (
            is => 'rw',
            traits => ['Private'],
        );
    }
    
    sub key{
        return $sk;
    }
    
    sub exit{
        return $_[0]->runcmd($sk . 'exit');
    }
    
    sub getvar{
        return eval($_[0]->runcmd($sk . 'sendvar \'' . $_[1] . '\''));
    }
    
    sub subsh{
        return $_[0]->runcmd($sk . 'subsh');
    }
    
    sub sudo{
        return $_[0]->runcmd($sk . 'sudo');
    }

    sub join{
        return $_[0]->thread->join;
    }
    
    sub getallvars{
        return $_[0]->execfunc($sk . 'allvars');
    }
    
    sub execfunc{
        return $_[0]->runcmd($sk . 'sendexec \'' . $_[1] . '\'');        
    }
    
    sub getcmd{
        return $_[0]->runcmd($sk . 'getcmd \'' . $_[1] . '\'');        
    }
    
    private_method flush => sub{
        my $self = shift;
        open (my $hd1, "+<", $self->input);
        syswrite $hd1, "", 0;
        open (my $hd2, "+<", $self->output);
        syswrite $hd2, "", 0;
    };
    
    sub close {
        my $self = shift;
        my $pid = $self->pid;
        if ( defined $pid){
            kill 9, $pid;
            $self->flush;
            $self->pid(undef);
            $self->thread()->join();
            $self->thread(undef);
        }
    }
    
    private_method open => sub {
        my $self = shift;
        my $pid = $self->pid();
        if (! defined $pid ){
            mkfifo($self->input, 0777);
            mkfifo($self->output, 0777);
            my $name = $self->temp;
            my $bash = $self->bash;
            my $pid = open3('<STDIN', '>&STDOUT', '>&STDERR',
                'env', "${sk}temp=$name", 
                $bash, '-c', $BASH_PROGRAM);
            my $th = threads->create(
            sub{
                waitpid $pid, 0;
                $self->flush();
                $self->close();
            });
            $self->thread($th);
            $self->pid($pid);
        } 
    };
    
    sub init{
        my $self = shift;
        my $mutex = $self->lockcmd();
        $mutex->lock();
        $self->open();
        $mutex->unlock();
    }

    sub source{
        my ($self, $path) = @_;
        $path = bstring(abs_path($path));
        $self->runcmd(". $path");
    }
    
    sub runcmd{
        my $self = shift;
        my $data = shift;
        my $mutex = $self->lockcmd();
        
        $mutex->lock();
        
        $self->open();
        $self->send ($data);
        
        $data = $self->recv();
        
        $mutex->unlock();
        
        return $data;
    }
    
    private_method send => sub {
        my $self = shift;
        my $data = shift;
        my $file = $self->input;
        my $handle1 = gensym;
        CORE::open ($handle1, ">" . $file);
        CORE::syswrite $handle1, $data, length $data;
        CORE::close $handle1;
    };
    
    private_method recv => sub {
        my $self = shift;
        my $file = $self->output;
        my $data;
        my $handle2 = gensym;
        CORE::open($handle2, "<" . $file);
        CORE::sysread $handle2, $data, 9999;
        CORE::close $handle2;
        return $data;
    };

    sub bstring{ my $k = $_[0]; $k = "$k"; $k =~ s/'/'"'"'/g; $k =~ s/\t/'"\\t"'/g; $k =~ s/\n/'"\\n"'/g; $k =~ s/\f/'"\\f"'/g; return "'$k'"; }

    sub bash_format{
        my ($name, $value, $type) = @_;
        # check type 
        die "class method invoked on object" if ref $name;
        
        my $subr;
        my @list=('typeset ');
        my $is_int = $type =~ /i/; 
        
        if ($is_int){
            push @list, '-i ';
            $subr = sub{
                return 0 + $_[0];
            }
        } else {
            $subr = &bstring;
        }


        if ($type =~ /A/){
            push @list, '-A ', $name, '=(';
            while (my ($k, $v) = each (%$value)){
                push @list, ' [', bstring($k), ']=', &$subr("$v");
            }
            ret:
            push @list, ' )';
            ret1:
            return CORE::join('', @list);
        } else {
            if ($type =~ /a/){
                push @list, '-a ', $name, '=(';
                for my $v (@$value){
                    push @list, ' ', &$subr("$v");
                }
                goto ret;
            } else {
                push @list, $name, '=', &$subr("$value");
                goto ret1;
            }
        }
    }
    
    sub setvar {
        my ($self, $name, $value, $type) = @_;
        return $self->runcmd(bash_format($name, $value, $type));   
    }

    sub BUILDARGS{
        shift;
        my $temp = mkdtemp(catfile(get_user_tempdir(), ${sk}."XXXXXXXX"));
        return {
        'bash', 'bash',
        @_,
        'temp', $temp,
        'input', catfile($temp, 'input.sock'), 
        'output', catfile($temp, 'output.sock'),
        'lockcmd', Mutex->new,
        };
    }
    
=head1 SYNOPSIS

This module will span an bash session

Little code snippet.

    use IPC::Bash;


    use Data::Dumper;
    srand();
    my @arr=('ksh', 'zsh', 'bash');
    
    my $var = IPC::Bash->new('bash' => $arr[rand @arr]);
    $var->init();
    
    $var->runcmd('typeset -i fin=33');
    $var->runcmd('typeset -p fin');
    $var->runcmd($var->key() . 'vartype fin');
    $var->runcmd('echo $$');
    $var->runcmd('echo $0');
    $var->subsh();
    $var->sudo();
    $var->runcmd('echo $$');
    my $sudouser = $var->getvar('SUDO_USER');
    $var->exit();
    $var->runcmd('echo $$');
    print Dumper($sudouser);
    
    if (defined $sudouser){
        $var->exit();
        $var->runcmd('echo $$');
    }
    
    print Dumper($var->getvar('fin'));
    $var->close();

    ...

=head1 SUBROUTINES/METHODS

=head2 exit()
    exit from current subshell
    
=head2 subsh()
    call subshell
    
=head2 sudo()
    call subshell with sudo

=head2 getvar(I<name>)
    get variable value
    
=head2 setvar(I<name> I<value> I<type>)
    set variable by name of type

=head2 key()
    get module key for accessing hidden functions
    
=head2 join()
    wait until session closed

=head2 static bstring(name)
    convert string to bash string implementation
    
=head2 source(name)
    execute 'source' command

=head2 execfunc(I<name>)
    get function output
    
=head2 close()
    close bash session
    
=head2 runcmd(I<str>)
    run session command
    
=head2 getcmd(I<str>)
    run session command and get output
    
=head2 getallvars()
    run shell state
    
=head2 
=cut

=head1 AUTHOR

huakim-tyk, C<< <zuhhaga at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-ipc-bash at rt.cpan.org>, or through
the web interface at L<https://rt.cpan.org/NoAuth/ReportBug.html?Queue=IPC-Bash>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc IPC::Bash


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<https://rt.cpan.org/NoAuth/Bugs.html?Dist=IPC-Bash>

=item * CPAN Ratings

L<https://cpanratings.perl.org/d/IPC-Bash>

=item * Search CPAN

L<https://metacpan.org/release/IPC-Bash>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2023 by huakim-tyk.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)


=cut

1; # End of IPC::Bash

