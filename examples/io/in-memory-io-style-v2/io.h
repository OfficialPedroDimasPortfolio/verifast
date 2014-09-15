﻿#ifndef IO_IMPL_GH
#define IO_IMPL_GH

/**
 * Bodies of I/O style contract predicates.
 *
 * This file contains bodies for the predicates
 * write, read, split and join. It supports
 * nested split/joins.
 *
 * Here, a time-value is a 6-tuple:
 * - fixpoint(list<int>, bool) invar:
 *   Invariant which represents the possible states.
 * - fixpoint(list<int>, list<int>, bool) guarantee_acum,
 *   Transitions of states this thread can do up to this time.
 *   This relation gets bigger as time progresses.
 * - fixpoint(list<int>, list<int>, bool) guarantee_thread,
 *   Transitions of states this thread can do, including in the future
 *   This is up to the join of this thread.
 * - list<fixpoint(list<int>, list<int>, bool)> guarantee_stack,
 *   The acumulated guarantee relation before the last split.
 *   Because join-split can be nested, this is a list.
 * - fixpoint(list<int>, list<int>, bool) rely,
 *   Transitions all other threads can perform in the past and in the future.
 * - list<fixpoint(list<int>, list<int>, bool)> rely_stack1
 *   Rely-relation before the last split.
 *   Because join-split can be nested, this is a list.
 */

//@ #include <quantifiers.gh>
//@ #include "../in-memory-io-style/helpers/cooked_ghost_lists.gh"
#include <threading.h>
#include "prophecy.h"


//-------------// buffer //-------------//

/**
 *
 * todo -> +--------+
 *         |        |
 *         |        |
 *         +--------+
 * done -> | done3  |
 *         | done2  |
 *         | ...    |
 *         +--------+
 */
struct buffer{
  char *todo;
  char *done;
  int size;
};

// Does not have to be global, but if it is then you can support C APIs that
// require this (like putchar).
static struct buffer *global_buffer;

/*@

predicate buffer(list<int> actions) =
  global_buffer |-> ?buffer_ptr
  &*& buffer_ptr->todo |-> ?todo
  &*& buffer_ptr->done |-> ?done
  &*& buffer_ptr->size |-> ?size
  &*& chars(todo, ?nb_todo, _)
  &*& chars(done, ?nb_done, ?done_chars)
  &*& nb_todo + nb_done == size
  &*& todo + nb_todo == done
  &*& done_chars == actions
;
@*/

//-------------// write //-------------//
/*@
fixpoint bool invar_fp_helper(
  fixpoint(list<int>, bool) invar1,
  fixpoint(list<int>, list<int>, bool) guarantee_acum2,
  fixpoint(list<int>, list<int>, bool) rely1,
  list<int> actions,
  //---curry away above
  pair<list<int>, list<int> > sigmapair
){
  return
    ! (
      invar1(fst(sigmapair))
      && guarantee_acum2(fst(sigmapair), snd(sigmapair))
      && rely1(snd(sigmapair), actions)
    )
  ;
}

// invar2(sigma) == ∃ sigma1, sigma 2 . invar1(sigma1) && guarantee2(sigma1, sigma2) && rely(sigma2, sigma)
fixpoint bool invar_fp(
  fixpoint(fixpoint(pair<list<int>, list<int> >, bool), bool) forall_fp,
  fixpoint(list<int>, bool) invar1,
  fixpoint(list<int>, list<int>, bool) guarantee2,
  fixpoint(list<int>, list<int>, bool) rely1,
  //---curry away above
  list<int> actions
){
  return
    false == forall_fp((invar_fp_helper)(invar1, guarantee2, rely1, actions));
}

fixpoint bool write_guarantee_acum_fp(
  fixpoint(list<int>, list<int>, bool) guarantee_acum1,
  fixpoint(list<int>, bool) invar1,
  int c,
  //---curry away above
  list<int> actions1,
  list<int> actions2
){
  return
    guarantee_acum1(actions1, actions2)
    || (
      invar1(actions1) && actions2 == cons(c, actions1)
    )
  ;
}


predicate write_io(
  time t1,
  int c,
  time t2
) =
  t1 == time(?invar1, ?guarantee_acum1, ?guarantee_thread1, ?guarantee_stack1, ?rely1, ?rely_stack1)
  &*& t2 == time(?invar2, ?guarantee_acum2, ?guarantee_thread2, ?guarantee_stack2, ?rely2, ?rely_stack2)
  
  &*& guarantee_thread2 == guarantee_thread1
  &*& rely2 == rely1
  &*& rely_stack2 == rely_stack1
  
  &*& guarantee_acum2 == (write_guarantee_acum_fp)(guarantee_acum1, invar1, c)
  
  &*& [_]is_forall_t<pair<list<int>, list<int> > >(?forall_sigmapair)
  &*& invar2 == (invar_fp)(forall_sigmapair, invar1, guarantee_acum2, rely1);

@*/

//-------------// read //-------------//
/*@


fixpoint list<t> remove_last<t>(list<t> xs){
  switch(xs){
    case nil: return nil; // should not happen in recursive call.
    case cons(xs_head, xs_tail):
      return xs_tail == nil ? nil : remove_last(xs_tail);
  }
}

fixpoint t last<t>(list<t> xs){
  switch(xs){
    case nil: return default_value<t>;
    case cons(xs_head, xs_tail):
      return xs_tail == nil ? xs_head : last(xs_tail);
  }
}

fixpoint bool read_guarantee_acum_fp(
  fixpoint(list<int>, list<int>, bool) guarantee_acum1,
  fixpoint(list<int>, bool) invar1,
  int c,
  //---curry away above
  list<int> actions1,
  list<int> actions2
){
  // actions1 != nil says you can only read if there is something to read. An implementation can block or not advance time.
  // "c == head(actions(1)" expresses you can only read if c is the thing that will be read.
  // The implementation thus has to block until c is the next thing to read, or it has to not perform any
  // read if something else is going to be read.
  return
    guarantee_acum1(actions1, actions2)
    || (
      invar1(actions1) && actions1 != nil && actions2 == remove_last(actions1) && c == last(actions1)
    )
  ;
}

fixpoint bool read_prophecy_helper(
  int c,
  fixpoint(list<int>, bool) invar1,
  //---curry away above
  list<int> sigma
){
  return ! (invar1(sigma) && sigma != nil && last(sigma) == c);
}

fixpoint bool read_prophecy(
  fixpoint(list<int>, bool) invar1,
  fixpoint(fixpoint(list<int>, bool), bool) forall_fp,
  //---curry away above
  int c
){
  return ! forall_fp((read_prophecy_helper)(c, invar1));
}

fixpoint bool not<t>(fixpoint(t, bool) fp, t t){
  return ! fp(t);
}

predicate read_io(
  time t1,
  int c,
  time t2
) =
  t1 == time(?invar1, ?guarantee_acum1, ?guarantee_thread1, ?guarantee_stack1, ?rely1, ?rely_stack1)
  &*& t2 == time(?invar2, ?guarantee_acum2, ?guarantee_thread2, ?guarantee_stack2, ?rely2, ?rely_stack2)
  
  &*& guarantee_thread2 == guarantee_thread1
  &*& rely_stack2 == rely_stack1
  &*& rely2 == rely1
  
  &*& guarantee_acum2 == (read_guarantee_acum_fp)(guarantee_acum1, invar1, c)
  
  &*& [_]is_forall_t<  pair< list<int>, list<int> >  >(?forall_sigmapair)
  &*& invar2 == (invar_fp)(forall_sigmapair, invar1, guarantee_acum2, rely1)
  
  // Normally, you need something like: 
  //    read_prophecy(c) || ∀c'. !read_prophecy(c')
  // but prophecy.h already does that for us: if 
  // there is no c' for which the prophecy-invariant holds,
  // then you cannot use the prophecy.
  &*& [_]is_forall_t< list<int> >(?forall_sigma)
  &*& prophecy_int((read_prophecy)(invar1, forall_sigma), c)
;

@*/
//-------------// join //-------------//
/*@

fixpoint bool join_invar(
  fixpoint(list<int>, bool) invar1,
  fixpoint(list<int>, bool) invar2,
  //---curry away above
  list<int> actions
){
  return invar1(actions) || invar2(actions);
}

fixpoint bool join_guarantee(
  fixpoint(list<int>, list<int>, bool) guarantee1,
  fixpoint(list<int>, list<int>, bool) guarantee2,
  //---curry away above
  list<int> actions1,
  list<int> actions2
){
  return guarantee1(actions1, actions2) || guarantee2(actions1, actions2);
}

fixpoint bool join_rely(
  fixpoint(list<int>, list<int>, bool) rely1,
  fixpoint(list<int>, list<int>, bool) rely2,
  //---curry away above
  list<int> actions1,
  list<int> actions2
){
  return rely1(actions1, actions2) && rely2(actions1, actions2);
}

fixpoint bool join_guarantee_acum(
  list<fixpoint(list<int>, list<int>, bool)> guarantee_stack1,
  fixpoint(list<int>, list<int>, bool) guarantee_acum1,
  fixpoint(list<int>, list<int>, bool) guarantee_acum2,
  //---curry away above
  list<int> actions1,
  list<int> actions2
){
  return (head(guarantee_stack1))(actions1, actions2) || guarantee_acum1(actions1, actions2) || guarantee_acum2(actions1, actions2);
}


predicate join(
  time t1,
  time t2,
  time t3
) =
  t1 == time(?invar1, ?guarantee_acum1, ?guarantee_thread1, ?guarantee_stack1, ?rely1, ?rely_stack1)
  &*& t2 == time(?invar2, ?guarantee_acum2, ?guarantee_thread2, ?guarantee_stack2, ?rely2, ?rely_stack2)
  &*& t3 == time(?invar3, ?guarantee_acum3, ?guarantee_thread3, ?guarantee_stack3, ?rely3, ?rely_stack3)
  
  // TODO: do we need to make this transitive? (note that rely is already transitive)
  &*& guarantee_thread1 == guarantee_acum1
  &*& guarantee_thread2 == guarantee_acum2
  
  &*& invar3 == (join_invar)(invar1, invar2)
  
  &*& guarantee_acum3 == (join_guarantee_acum)(guarantee_stack1, guarantee_acum1, guarantee_acum2)
  
  &*& guarantee_stack3 == tail(guarantee_stack1)
  
  &*& rely_stack3 == tail(rely_stack1)
  
  &*& rely3 == head(rely_stack1)
  
  &*& (guarantee_stack1 != guarantee_stack2 ? exists<list<char> >({'e','r','r','o','r'}):emp)
  &*& (rely_stack1 != rely_stack2 ? exists<list<char> >({'e','r','r','o','r'}):emp)
;
  


lemma void join()
requires join(?t1, ?t2, ?t3) &*& time(t1) &*& time(t2);
ensures time(t3);
{
  assume(false); // XXX TODO
}

@*/

//-------------// split //-------------//

/*@
fixpoint bool split_invar_fp_helper(
  fixpoint(list<int>, bool) invar1,
  fixpoint(list<int>, list<int>, bool) rely2,
  list<int> sigma,
  //---curry away above
  list<int> sigma_A
){
  return
    ! (
      invar1(sigma_A)
      && rely2(sigma_A, sigma)
    )
  ;
}

// invar2(sigma) == ∃ sigma_A . invar1(sigma_A) && rely2(sigma_A, sigma)
fixpoint bool split_invar(
  fixpoint(fixpoint(list<int>, bool), bool) forall_sigma,
  fixpoint(list<int>, bool) invar1,
  fixpoint(list<int>, list<int>, bool) rely2,
  //---curry away above
  list<int> actions
){
  return
    false == forall_sigma((split_invar_fp_helper)(invar1, rely2, actions));
}

fixpoint bool sigma_id(
  list<int> sigma1, list<int> sigma2)
{
  return sigma2 == sigma1;
}

fixpoint bool split_rely_non_transitive(
  fixpoint(list<int>, list<int>, bool) rely1,
  fixpoint(list<int>, list<int>, bool) guarantee_other_thread,
  //---curry away above
  list<int> actions1,
  list<int> actions2
){
  return rely1(actions1, actions2) || guarantee_other_thread(actions1, actions2);
}

fixpoint bool transitive_closure_helper_helper(
  fixpoint(list<int>, list<int>, bool) transition_fp,
  //--- curry away above
  list<list<int> > intermediate_sigmas
){
  switch (intermediate_sigmas){
    case nil:
      return false;
    case cons(h, t):
      return t == nil ? false : transition_fp(h, head(t)) && transitive_closure_helper_helper(transition_fp, t);
  }
}


fixpoint bool transitive_closure_helper(
  fixpoint(list<int>, list<int>, bool) transition_fp,
  list<int> sigma1,
  list<int> sigma2,
  //--- curry away above
  list<list<int> > intermediate_sigmas
){
  return ! transitive_closure_helper_helper(transition_fp, cons(sigma1, append(intermediate_sigmas, {sigma2})));
}

// Informally: there is a list "sigmas", such that
//   transition_fp(sigma1, sigmas_1) && transition_fp(sigmas_2, sigmas_3)
//   && ... && transition_fp(sigmas_n, sigma2).
fixpoint bool transitive_closure(
  fixpoint(fixpoint(list<list<int> >, bool), bool) forall_list_sigma,
  fixpoint(list<int>, list<int>, bool) transition_fp,
  //--- curry away above
  list<int> sigma1,
  list<int> sigma2
){
  return ! forall_list_sigma((transitive_closure_helper)(transition_fp, sigma1, sigma2));
}


predicate split(
  time t1,
  time t2,
  time t3
) =
  t1 == time(?invar1, ?guarantee_acum1, ?guarantee_thread1, ?guarantee_stack1, ?rely1, ?rely_stack1)
  &*& t2 == time(?invar2, ?guarantee_acum2, ?guarantee_thread2, ?guarantee_stack2, ?rely2, ?rely_stack2)
  &*& t3 == time(?invar3, ?guarantee_acum3, ?guarantee_thread3, ?guarantee_stack3, ?rely3, ?rely_stack3)
  
  &*& guarantee_acum2 == sigma_id
  &*& guarantee_acum3 == sigma_id
  
  // guarantee_thread2: unspecified (specified by join predicate)
  
  &*& [_]is_forall_t<list<list<int> > >(?forall_list_sigma)
  
  &*& rely2 == (transitive_closure)(forall_list_sigma, (split_rely_non_transitive)(rely1, guarantee_thread3))
  &*& rely3 == (transitive_closure)(forall_list_sigma, (split_rely_non_transitive)(rely1, guarantee_thread2))
  
  &*& rely_stack2 == cons(rely1, rely_stack1)
  &*& rely_stack3 == cons(rely1, rely_stack1)
  
  &*& guarantee_stack2 == cons(guarantee_acum1, guarantee_stack1)
  &*& guarantee_stack3 == cons(guarantee_acum1, guarantee_stack1)
  
  &*& [_]is_forall_t<list<int> >(?forall_sigma)
  
  &*& invar2 == (split_invar)(forall_sigma, invar1, rely2)
  &*& invar3 == (split_invar)(forall_sigma, invar1, rely3)
;

    
lemma void split()
requires split(?t1, ?t2, ?t3) &*& time(t1);
ensures time(t2) &*& time(t3);
{
  assume(false); // XXX TODO
}

@*/


//-------------// core //-------------//
/*@

fixpoint bool invar_init(list<int> ioactions){
  return ioactions == {};
}

/** Time after program startup, i.e. no I/O happened */
predicate is_initial_time(time t) =
  t == time(invar_init, sigma_id /*guarantee_acum_init*/, sigma_id /*guarantee_thread_init*/, nil /*guarantee_stack_init*/, sigma_id /*rely_init*/, nil /*rely_stack_init */);

predicate time(
  time t
);
// = emp; // TODO

inductive time = time(
  fixpoint(list<int>, bool) invar1,
  fixpoint(list<int>, list<int>, bool) guarantee_acum1,
  fixpoint(list<int>, list<int>, bool) guarantee_thread1,
  list<fixpoint(list<int>, list<int>, bool)> guarantee_stack1,
  fixpoint(list<int>, list<int>, bool) rely1,
  list<fixpoint(list<int>, list<int>, bool)> rely_stack1
  );
fixpoint fixpoint(list<int>, bool) time_invar(time t){ switch(t){ case time(invar, guarantee_acum, guarantee_thread, guarantee_stack, rely, rely_stack): return invar; } }

fixpoint bool invar_holds(list<int>actionlist, pair<int, time> ktime){
  return (time_invar)(snd(ktime))(actionlist);
}

predicate iostate(int ghost_list_id, list<int> actionlist) =
  buffer(actionlist)
  
  &*& cooked_ghost_list<time>(ghost_list_id, _, ?k_time_pairs)
  
  &*& true==distinct(k_time_pairs)
    
  // For all times, invar holds for the current actionlist:
  &*& true == forall(k_time_pairs, (invar_holds)(actionlist))
    
  // We also have the following properties (can be useful te have as invariant in this predicate)
  // 
  // Guarantee of one time/thread implies rely of all other times/threads:
  // ∀ t1,t2 ∈ active_times . ∀ sigma1, sigma2 . t1 != t2 => t1.guarantee_thread(sigma1, sigma2) => t2.rely(sigma1, sigma2)
  //
  // Rely of one thread preserves invar of said thread. For a given time/thread, invar(sigma)->rely(sigma,sigma2)->invar(sigma2)
  // ∀ t ∈ active_times . ∀ sigma1, sigma2 . t.invar(sigma1) => t.rely(sigma1, sigma2) => t.invar(sigma2)
;

predicate iostate_shared() = 
  // TODO put it in a mutex.
  iostate(_, _);
  
@*/

#endif
