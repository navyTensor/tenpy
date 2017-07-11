r"""Basic definitions of a charge.

Contains implementation of classes
:class:`ChargeInfo`,
:class:`LegCharge` and
:class:`LegPipe`.

.. note ::
    The contents of this module are imported in :mod:`~tenpy.linalg.np_conserved`,
    so you usually don't need to import this module in your application.

.. todo ::
    change: take ChargeInfo.mod[j]=0 for U(1) (instead of mod=1)
    Adjust doc strings

A detailed introduction to `np_conserved` can be found in :doc:`../IntroNpc`.
"""

from __future__ import division

import numpy as np
cimport numpy as np
cimport cython

import copy
import itertools
import bisect
import warnings

from ..tools.misc import lexsort, inverse_permutation
from ..tools.string import vert_join

__all__ = ['ChargeInfo', 'LegCharge', 'LegPipe']

np.import_array()

QTYPE = np.int_             # numpy dtype for the charges
ctypedef np.int_t QTYPE_t   # compile time type for QTYPE


cdef class ChargeInfo(object):
    """Meta-data about the charge of a tensor.

    Saves info about the nature of the charge of a tensor.
    Provides :meth:`make_valid` for taking modulo `m`.

    (This class is implemented in :mod:`tenpy.linalg.charges` but also imported in
    :mod:`tenpy.linalg.np_conserved` for convenience.)

    Parameters
    ----------
    mod : iterable of QTYPE
        The len gives the number of charges, `qnumber`.
        For each charge one entry `m`: the charge is conserved modulo `m`.
        Defaults to trivial, i.e., no charge.
    names : list of str
        Descriptive names for the charges.  Defaults to ``['']*qnumber``.

    Attributes
    ----------
    qnumber :
        The number of charges.
    mod :  ndarray[QTYPE,ndim=1]
        Modulo how much each of the charges is taken.
        1 for a  (i.e. mod 1-> mod infinity)
    names : list of strings
        A descriptive name for each of the charges.  May have '' entries.

    Notes
    -----
    Instances of this class can (should) be shared between different `LegCharge` and `Array`'s.
    """
    cdef readonly int qnumber
    cdef readonly np.ndarray mod
    cdef list names

    def __init__(ChargeInfo self, mod=[], names=None):
        """see help(self)"""
        mod = np.asarray(mod, dtype=QTYPE)
        self.qnumber = len(mod)
        self.mod = mod
        if names is None:
            names = [''] * self.qnumber
        self.names = [str(n) for n in names]
        self.test_sanity()  # checks for invalid arguments

    def test_sanity(self):
        """Sanity check. Raises ValueErrors, if something is wrong."""
        if len(self.names) != self.qnumber:
            raise ValueError("names has incompatible length with mod")
        if np.any(self.mod < 0):
            raise ValueError("mod with negative entries???")


    cpdef np.ndarray make_valid(ChargeInfo self, charges=None):
        """Take charges modulo self.mod.

        Acts in-place, if charges is an array.

        .. todo : fast indexing requirese 1D/2D version
            Save default charges in self?

        Parameters
        ----------
        charges : array_like or None
            1D or 2D array of charges, last dimension `self.qnumber`
            None defaults to np.zeros(qnumber).

        Returns
        -------
        charges :
            A copy of `charges` taken modulo `mod`, but with ``x % 1 := x``
        """
        if charges is None:
            return np.zeros((self.qnumber, ), dtype=QTYPE)
        charges = np.asarray(charges, dtype=QTYPE)
        if charges.ndim == 1:
            assert(charges.shape[0] == self.qnumber)
            return self._make_valid_1D(charges)
        elif charges.ndim == 2:
            assert(charges.shape[1] == self.qnumber)
            return self._make_valid_2D(charges)
        raise ValueError("wrong dimension of charges " + str(charges))

    @cython.wraparound(False)
    @cython.boundscheck(False)
    @cython.cdivision(True)
    cdef np.ndarray[QTYPE_t,ndim=1] _make_valid_1D(ChargeInfo self, np.ndarray[QTYPE_t,ndim=1] charges):
        cdef np.ndarray[QTYPE_t,ndim=1] res = np.empty_like(charges)
        cdef int j
        cdef QTYPE_t q
        for j in range(self.qnumber):
            q = self.mod[j]
            if q == 1:
                res[j] = charges[j]
            else:
                res[j] = charges[j]  % q
                if res[j] < 0:  # correct for C-modulo opposed to python modulo
                    res[j] += q
        return res

    @cython.wraparound(False)
    @cython.boundscheck(False)
    @cython.cdivision(True)
    cdef np.ndarray _make_valid_2D(ChargeInfo self, np.ndarray[QTYPE_t,ndim=2] charges):
        cdef np.ndarray[QTYPE_t,ndim=2] res = np.empty_like(charges)
        cdef np.ndarray[QTYPE_t,ndim=1] mod = self.mod
        cdef int L = charges.shape[0]
        cdef int i, j
        cdef QTYPE_t q, x
        for j in range(self.qnumber):
            q = mod[j]
            if q == 1:
                for i in range(L):
                    res[i, j] = charges[i, j]
            else:
                for i in range(L):
                    res[i, j] = charges[i, j] % q
                    if res[i, j] < 0:  # correct for C-modulo opposed to python modulo
                        res[i, j] += q
                    continue
        return res

    @cython.wraparound(False)
    @cython.boundscheck(False)
    @cython.cdivision(True)
    def check_valid(ChargeInfo self, np.ndarray[QTYPE_t,ndim=2] charges):
        r"""Check, if `charges` has all entries as expected from self.mod.

        Parameters
        ----------
        charges : 2D ndarray QTYPE_t
            Charge values to be checked.

        Returns
        -------
        res : bool
            True, if all 0 <= charges <= self.mod (wherever self.mod != 1)
        """
        assert (charges.shape[1] == self.qnumber)
        cdef np.ndarray[QTYPE_t,ndim=1] mod = self.mod
        cdef int i, j, x
        cdef QTYPE_t q
        cdef L = charges.shape[0]
        for j in range(self.qnumber):
            q = mod[j]
            if q == 1:
                continue
            for i in range(L):
                x = charges[i, j]
                if x < 0 or x >= q:
                    print "invalid at ", i , ",",  j
                    return False
        return True

    def __repr__(self):
        """full string representation"""
        return "ChargeInfo({0!s}, {1!s})".format(list(self.mod), self.names)

    def __richcmp__(self, other, int operator):
        if operator == 2: # equal:
            return self._equal(other)
        elif operator == 3:
            return not self._equal(other)
        else:
            raise NotImplementedError("No ordering of `ChargeInfo` possible")

    def _equal(self, other):
        r"""compare self.mod and self.names for equality, ignore missing names."""
        if self is other:
            return True
        if not np.all(self.mod == other.mod):
            return False
        for l, r in itertools.izip(self.names, other.names):
            if r != l and l != '' and r != '':
                return False
        return True

    def __getstate__(self):
        """allow to pickle and copy"""
        return (self.qnumber, self.mod, self.names)

    def __setstate__(self, state):
        """allow to pickle and copy"""
        qnumber, mod, names = state
        self.qnumber = qnumber
        self.mod = mod
        self.names = names


cdef class LegCharge(object):
    r"""Save the charge data associated to a leg of a tensor.

    This class is more or less a wrapper around a 2D numpy array `charges` and a 1D array `slices`.
    See :doc:`../IntroNpc` for more details.

    (This class is implemented in :mod:`tenpy.linalg.charges` but also imported in
    :mod:`tenpy.linalg.np_conserved` for convenience.)

    Parameters
    ----------
    chargeinfo : :class:`ChargeInfo`
        the nature of the charge
    slices: 1D array_like, len(block_number+1)
        A block with 'qindex' ``qi`` correspondes to the leg indices in
        ``slice(slices[qi], slices[qi+1])``.
    charges : 2D array_like, shape(block_number, chargeinfo.qnumber)
        ``charges[qi]`` gives the charges for a block with 'qindex' ``qi``.
    qconj : {+1, -1}
        A flag telling whether the charge points inwards (+1, default) or outwards (-1).

    Attributes
    ----------
    ind_len
    block_number
    chinfo : :class:`ChargeInfo` instance
        the nature of the charge. Can be shared between LegCharges
    slices : ndarray[QTYPE_t,ndim=1] (block_number+1)
        A block with 'qindex' ``qi`` correspondes to the leg indices in
        ``slice(self.slices[qi], self.slices[qi+1])``. See :meth:`get_slice`.
    charges : ndarray[QTYPE_t,ndim=1] (block_number, chinfo.qnumber)
        ``charges[qi]`` gives the charges for a block with 'qindex' ``qi``.
        Note: the sign might be changed by `qconj`. See also :meth:`get_charge`.
    qconj : {-1, 1}
        A flag telling whether the charge points inwards (+1) or outwards (-1).
        Whenever charges are added, they should be multiplied with their `qconj` value.
    sorted : bool
        whether the charges are guaranteed to be sorted
    bunched : bool
        whether the charges are guaranteed to be bunched

    Notes
    -----
    Instances of this class can be shared between different `npc.Array`.
    Thus, functions changing ``self.slices`` or ``self.charges`` *must* always make copies.
    Further they *must* set `sorted` and `bunched` to ``False`` (if they might not preserve them).
    """
    cdef readonly int ind_len
    cdef readonly int block_number
    cdef readonly ChargeInfo chinfo
    cdef readonly np.ndarray slices
    cdef readonly np.ndarray charges
    cdef readonly int qconj
    cdef public bint sorted
    cdef public bint bunched

    def __init__(LegCharge self, chargeinfo, slices, charges, qconj=1):
        """see help(self)"""
        self.chinfo = chargeinfo
        self.slices = np.array(slices, dtype=QTYPE)
        self.charges = np.array(charges, dtype=QTYPE)
        self.qconj = qconj
        self.sorted = False
        self.bunched = False
        self.ind_len = self.slices[-1]
        self.block_number = self.charges.shape[0]
        LegCharge.test_sanity(self)

    @classmethod
    def from_trivial(cls, ind_len, chargeinfo=None, qconj=1):
        """create trivial (qnumber=0) LegCharge for given len of indices `ind_len`"""
        if chargeinfo is None:
            chargeinfo = ChargeInfo()
        return cls(chargeinfo, [0, ind_len], [[]], qconj)

    @classmethod
    def from_qflat(cls, chargeinfo, qflat, qconj=1):
        """create a LegCharge from qflat form.

        Does *neither* bunch *nor* sort. We recommend to sort (and bunch) afterwards,
        if you expect that tensors using the LegCharge have entries at all positions compatible
        with the charges.

        Parameters
        ----------
        chargeinfo : :class:`ChargeInfo`
            the nature of the charge
        qflat : array_like (ind_len, `qnumber`)
            `qnumber` charges for each index of the leg on entry
        qconj : {-1, 1}
            A flag telling whether the charge points inwards (+1) or outwards (-1).

        See also
        --------
        :meth:`sort` : sorts by charges
        :meth:`bunch` : bunches contiguous blocks of the same charge.
        """
        qflat = np.asarray(qflat, dtype=QTYPE)
        if qflat.ndim == 1 and chargeinfo.qnumber == 1:
            # accept also 1D arrays, if the qnumber is 1
            qflat = qflat.reshape(-1, 1)
        ind_len, qnum = qflat.shape
        if qnum != chargeinfo.qnumber:
            raise ValueError("qflat with second dimension != qnumber")
        res = cls(chargeinfo, np.arange(ind_len + 1), qflat, qconj)
        res.sorted = res.is_sorted()
        res.bunched = res.is_bunched()
        return res

    @classmethod
    def from_qind(cls, chargeinfo, slices, charges, qconj=1):
        """just a wrapper around self.__init__(), see class doc-string for parameters.

        See also
        --------
        sort : sorts by charges
        block : blocks by charges
        """
        res = cls(chargeinfo, slices, charges, qconj)
        res.sorted = res.is_sorted()
        res.bunched = res.is_bunched()
        return res

    @classmethod
    def from_qdict(cls, chargeinfo, qdict, qconj=1):
        """create a LegCharge from qdict form.

        Parameters
        ----------
        chargeinfo : :class:`ChargeInfo`
            the nature of the charge
        qdict : dict
            a dictionary mapping a tuple of charges to slices.
        """
        slices = np.array([(sl.start, sl.stop) for sl in qdict.values()], np.intp)
        charges = np.array(qdict.keys(), dtype=QTYPE).reshape((-1, chargeinfo.qnumber))
        sort = np.argsort(slices[:, 0])  # sort by slice start
        slices = slices[sort, :]
        charges = charges[sort, :]
        if np.any(slices[:-1, 1] != slices[1:, 0]):
            raise ValueError("The slices are not contiguous.\n" + str(slices))
        slices = np.append(slices[:, 0], [slices[-1, 1]])
        res = cls(chargeinfo, slices, charges, qconj)
        res.sorted = True
        res.bunched = res.is_bunched()
        return res

    def test_sanity(self):
        """Sanity check. Raises ValueErrors, if something is wrong."""
        cdef np.ndarray[QTYPE_t,ndim=1] sl = self.slices
        cdef np.ndarray[QTYPE_t,ndim=2] ch = self.charges
        if sl.ndim != 1 or sl.shape[0] != self.block_number + 1:
            raise ValueError("wrong len of `slices`")
        if sl[0] != 0:
            raise ValueError("slices does not start with 0")
        if ch.shape[1] != self.chinfo.qnumber:
            raise ValueError("shape of `charges` incompatible with qnumber")
        if not self.chinfo.check_valid(ch):
            raise ValueError("charges invalid for " + str(self.chinfo) + "\n" + str(self))
        if self.qconj != -1 and self.qconj != 1:
            raise ValueError("qconj has invalid value != +-1 :" + repr(self.qconj))


    cpdef LegCharge conj(LegCharge self):
        """return a (shallow) copy with opposite ``self.qconj``"""
        res = copy.copy(self)  # shallow
        (<LegCharge> res).qconj = - self.qconj
        return res

    def to_qflat(self):
        """return charges in `qflat` form"""
        qflat = np.empty((self.ind_len, self.chinfo.qnumber), dtype=QTYPE)
        for start, stop, ch in itertools.izip(self.slices[:-1], self.slices[1:], self.charges):
            qflat[slice(start, stop)] = ch
        return qflat

    def to_qdict(self):
        """return charges in `qdict` form. Raises ValueError, if not blocked."""
        res = dict()
        for start, stop, ch in itertools.izip(self.slices[:-1], self.slices[1:], self.charges):
            res[tuple(ch)] = slice(start, stop)
        if len(res) < self.block_number:  # ensures self is blocked
            raise ValueError("can't convert qflat to qdict for non-blocked LegCharge")
        return res

    cpdef bint is_blocked(self):
        """returns whether self is blocked, i.e. qindex map 1:1 to charge values."""
        if self.sorted and self.bunched:
            return True
        s = {tuple(c) for c in self.charges}  # a set has unique elements
        return (len(s) == self.block_number)

    def is_sorted(self):
        """returns whether `self.charges` is sorted lexiographically"""
        if self.chinfo.qnumber == 0:
            return True
        res = lexsort(self.charges.T)
        return np.all(res == np.arange(len(res)))

    def is_bunched(self):
        """checks wheter :meth:`bunch` would change something. """
        return len(_c_find_row_differences(self.charges)) == self.block_number + 1

    cpdef void test_contractible(LegCharge self, LegCharge other) except *:
        """Raises a ValueError if charges are incompatible for contraction with other.

        Parameters
        ----------
        other : :class:`LegCharge`
            The LegCharge of the other leg condsidered for contraction.

        Raises
        ------
        ValueError
            If the charges are incompatible for direct contraction.

        Notes
        -----
        This function checks that two legs are `ready` for contraction.
        This is the case, if all of the following conditions are met:

        - the ``ChargeInfo`` is equal
        - the `slices` are equal
        - the `charges` are the same up to *opposite* signs ``qconj``::

                self.charges * self.qconj = - other.charges * other.qconj

        In general, there could also be a change of the total charge, see :doc:`../IntroNpc`
        This special case is not considered here - instead use
        :meth:~tenpy.linalg.np_conserved.gauge_total_charge`, if a change of the charge is desired.

        If you are sure that the legs should be contractable,
        check whether the charges are actually valid
        or whether ``self`` and ``other`` are blocked or should be sorted.

        See also
        --------
        test_equal :
            ``self.test_contractible(other)`` just performs ``self.test_equal(other.conj())``.

        """
        self.test_equal(other.conj())

    cpdef void test_equal(LegCharge self, LegCharge other) except *:
        """test if charges are *equal* including `qconj`.

        Check that all of the following conditions are met:

        - the ``ChargeInfo`` is equal
        - the `slices` are equal
        - the `charges` are the same up to the signs ``qconj``::

                self.charges * self.qconj = other.charges * other.qconj

        See also
        --------
        test_contractible :
            ``self.test_equal(other)`` is equivalent to ``self.test_contractible(other.conj())``.
        """

        if self.chinfo != other.chinfo:
            raise ValueError(
                ''.join(["incompatible ChargeInfo\n", str(self.chinfo), str(other.chinfo)]))
        if self.charges is other.charges and self.qconj == other.qconj and \
                (self.slices is other.slices or np.all(self.slices == other.slices)):
            return  # optimize: don't need to check all charges explicitly
        if not np.array_equal(self.slices, other.slices) or \
                not np.array_equal(self.charges * self.qconj, other.charges * other.qconj):
            raise ValueError("incompatible LegCharge\n" + vert_join(
                ["self\n" + str(self), "other\n" + str(other)], delim=' | '))

    cpdef slice get_slice(LegCharge self, int qindex):
        """return slice selecting the block for a given `qindex`"""
        return slice(self.slices[qindex], self.slices[qindex + 1])

    def get_qindex(self, flat_index):
        """find qindex containing a flat index.

        Given a flat index, to find the corresponding entry in an Array, we need to determine the
        block it is saved in. For example, if ``qind[:, 2] = [[0, 3], [3, 7], [7, 12]]``,
        the flat index ``5`` corresponds to the second entry, ``qindex = 1`` (since 5 is in [3:7]),
        and the index within the block would be ``5-3 =2``.

        Parameters
        ----------
        flat_index : int
            a flat index of the leg. Negative index counts from behind.

        Returns
        -------
        qindex : int
            the qindex, i.e. the index of the block containing `flat_index`
        index_within_block : int
            the index of `flat_index` within the block given by `qindex`.
        """
        if flat_index < 0:
            flat_index += self.ind_len
            if flat_index < 0:
                raise IndexError("flat index {0:d} too negative for leg with ind_len {1:d}"
                                 .format(flat_index - self.ind_len, self.ind_len))
        elif flat_index > self.ind_len:
            raise IndexError("flat index {0:d} too large for leg with ind_len {1:d}"
                             .format(flat_index, self.ind_len))
        qind = bisect.bisect(self.slices, flat_index) - 1
        return qind, flat_index - self.slices[qind]

    def get_charge(self, qindex):
        """Return charge ``self.charges[qindex] * self.qconj`` for a given `qindex`."""
        return self.charges[qindex] * self.qconj

    def sort(LegCharge self, bint bunch=True):
        """Return a copy of `self` sorted by charges (but maybe not bunched).

        If bunch=True, the returned copy is completely blocked by charge.

        Parameters
        ----------
        bunch : bool
            whether `self.bunch` is called after sorting.
            If True, the leg is guaranteed to be fully blocked by charge.

        Returns
        -------
        perm_qind : array (self.block_len,)
            the permutation of the qindices (before bunching) used for the sorting.
            To obtain the flat permuation such that
            ``sorted_array[..., :] = unsorted_array[..., perm_flat]``, use
            ``perm_flat = unsorted_leg.perm_flat_from_perm_qind(perm_qind)``
        sorted_copy : :class:`LegCharge`
            a shallow copy of self, with new qind sorted (and thus blocked if bunch) by charges.

        See also
        --------
        bunch : enlarge blocks for contiguous qind of the same charges.
        np.take : can apply `perm_flat` to a given axis
        inverse_permutation : returns inverse of a permutation
        """
        if self.sorted and ((not bunch) or self.bunched):  # nothing to do
            return np.arange(self.block_number, dtype=np.intp), self
        perm_qind = lexsort(self.charges.T)
        cp = copy.copy(self)
        cp._set_charges(self.charges[perm_qind, :])
        block_sizes = self._get_block_sizes()
        cp._set_block_sizes(block_sizes[perm_qind])
        cp.sorted = True
        # finally bunch: re-ordering can have brought together equal charges
        if bunch:
            _, cp = cp.bunch()
        else:
            cp.bunched = False
        return perm_qind, cp

    def bunch(self):
        """Return a copy with bunched self.charges: form blocks for contiguous equal charges.

        Returns
        -------
        idx : 1D array
            ``idx[:-1]`` are the indices of the old qind which are kept,
            ``idx[-1] = old_block_number``.
        cp : :class:`LegCharge`
            a new LegCharge with the same charges at given indices of the leg,
            but (possibly) shorter ``self.charges`` and ``self.slices``.

        See also
        --------
        sort : sorts by charges, thus enforcing complete blocking in combination with bunch"""
        if self.bunched:  # nothing to do
            return np.arange(self.block_number+1, dtype=np.intp), self
        cp = copy.copy(self)
        idx = _c_find_row_differences(self.charges)
        cp._set_charges(cp.charges[idx[:-1]])  # avanced indexing -> copy
        cp._set_slices(cp.slices[idx])
        cp.bunched = True
        return idx, cp

    def project(self, mask):
        """Return copy keeping only the indices specified by `mask`.

        Parameters
        ----------
        mask : 1D array(bool)
            whether to keep of the indices

        Returns
        -------
        map_qind : 1D array
            map of qindices, such that ``qind_new = map_qind[qind_old]``,
            and ``map_qind[qind_old] = -1`` for qindices projected out.
        block_masks : 1D array
            the bool mask for each of the *remaining* blocks
        projected_copy : :class:`LegCharge`
            copy of self with the qind projected by `mask`
        """
        mask = np.asarray(mask, dtype=np.bool_)
        cp = copy.copy(self)
        block_masks = [mask[b:e] for b, e in self._slice_start_stop()]
        new_block_lens = [np.sum(bm) for bm in block_masks]
        keep = np.nonzero(new_block_lens)[0]
        block_masks = [block_masks[i] for i in keep]
        cp._set_charges(cp.charges[keep])
        map_qind = -np.ones(self.block_number, np.int_)
        map_qind[keep] = np.arange(len(keep))
        cp._set_block_sizes(np.array(new_block_lens)[keep])
        cp.bunched = self.is_blocked()  # no, it's not `is_bunched`
        return map_qind, block_masks, cp

    def charge_sectors(self):
        """Return unique rows of self.charges.

        Returns
        -------
        charges : 2D array
            Rows are the rows of self.charges lexsorted and without duplicates.
        """
        charges = self.charges.copy()
        if not self.sorted:
            charges = charges[np.lexsort(self.charges.T), :]
        charges = charges[_c_find_row_differences(charges)[:-1], :]
        return charges

    def __str__(self):
        """return a string of nicely formatted slices & charges"""
        qconj = " {0:+d}\n".format(self.qconj)
        slices = '\n'.join([str(s) for s in self.slices])
        return qconj + vert_join([slices, str(self.charges)], delim=' ')

    def __repr__(self):
        """full string representation"""
        return "LegCharge({0!r}, qconj={1:+d},\n{2!r}, {3!r})".format(self.chinfo, self.qconj,
                                                                      self.slices, self.charges)

    cpdef void _set_charges(LegCharge self, np.ndarray[QTYPE_t,ndim=2] charges):
        """provide hook to set 'private' charges"""
        self.charges = charges
        self.block_number = charges.shape[0]

    cpdef void _set_slices(LegCharge self, np.ndarray[np.intp_t,ndim=1] slices):
        self.slices = slices
        self.ind_len = slices[-1]

    cpdef _set_block_sizes(self, block_sizes):
        """Set self.slices from an list of the block-sizes."""
        self._set_slices(np.append([0], np.cumsum(block_sizes)).astype(np.intp, copy=False))

    cpdef _get_block_sizes(self):
        """return block sizes"""
        cdef np.ndarray[QTYPE_t,ndim=1] sl = self.slices
        return sl[1:] - sl[:-1]

    def _slice_start_stop(self):
        """yield (start, stop) for each qindex"""
        return itertools.izip(self.slices[:-1], self.slices[1:])

    def perm_flat_from_perm_qind(self, perm_qind):
        """Convert a permutation of qind (acting on self) into a flat permutation."""
        begend = np.stack([self.slices[:-1], self.slices[1:]], axis=0).T
        res = [np.arange(b, e) for b, e in begend[perm_qind]]
        return np.concatenate(res)

    def perm_qind_from_perm_flat(self, perm_flat):
        """Convert flat permutation into qind permutation.

        Parameters
        ----------
        perm_flat : 1D array
            a permutation acting on self, which doesn't mix the blocks of qind.

        Returns
        -------
        perm_qind : 1D array
            the permutation of self.qind described by perm_flat.

        Raises
        ------
        ValueError
            If perm_flat mixes blocks of different qindex
        """
        perm_flat = np.asarray(perm_flat)
        perm_qind = perm_flat[self.slices[:-1]]
        # check if perm_qind indeed resembles the permutation
        if np.any(perm_flat != self.perm_flat_from_perm_qind(perm_qind)):
            raise ValueError("Permutation mixes qind")
        return perm_qind

    def __getstate__(self):
        """allow to pickle and copy"""
        return (self.ind_len,
                self.block_number,
                self.chinfo,
                self.slices,
                self.charges,
                self.qconj,
                self.sorted,
                self.bunched)

    cpdef void __setstate__(LegCharge self, tuple state):
        """allow to pickle and copy"""
        ind_len, block_number, chinfo, slices, charges, qconj, sorted, bunched = state
        self.ind_len = ind_len
        self.block_number = block_number
        self.chinfo = chinfo
        self.slices = slices
        self.charges = charges
        self.qconj = qconj
        self.sorted = sorted
        self.bunched = bunched


cdef class LegPipe(LegCharge):
    r"""A `LegPipe` combines multiple legs of a tensor to one.

    Often, it is necessary to "combine" multiple legs into one:
    for example to perfom a SVD, the tensor needs to be viewed as a matrix.

    This class does exactly this job: it combines multiple LegCharges ('incoming legs')
    into one 'pipe' (*the* 'outgoing leg').
    The pipe itself is a :class:`LegCharge`, with indices running from 0 to the product of the
    individual legs' `ind_len`, corresponding to all possible combinations of input leg indices.

    (This class is implemented in :mod:`tenpy.linalg.charges` but also imported in
    :mod:`tenpy.linalg.np_conserved` for convenience.)

    Parameters
    ----------
    legs : list of :class:`LegCharge`
        the legs which are to be combined.
    qconj : {+1, -1}
        A flag telling whether the charge of the *resulting* pipe points inwards
        (+1, default) or outwards (-1).
    sort : bool
        Whether the outgoing pipe should be sorted. Defaults ``True``; recommended.
        Note: calling :meth:`sort` after initialization converts to a LegCharge.
    bunch : bool
        Whether the outgoing pipe should be bunched. Default ``True``; recommended.
        Note: calling :meth:`bunch` after initialization converts to a LegCharge.

    Attributes
    ----------
    nlegs
    legs : tuple of :class:`LegCharge`
        the original legs, which were combined in the pipe.
    subshape : tuple of int
        ind_len for each of the incoming legs
    subqshape : tuple of int
        block_number for each of the incoming legs
    q_map:  2D array
        shape (`block_number`, 2+`nlegs`+1). rows: ``[ m_j, m_{j+1}, i_1, ..., i_{nlegs}, I_s]``,
        see Notes below for details.
        # TODO re-order q_map[:, 2], q_map[:, 3:] := q_map[:, -1], q_map[:, 2:]
    q_map_slices : list of views onto q_map
        defined such that ``q_map_slices[I_s] == q_map[(q_map[:, -1] == I_s)]``
    _perm : 1D array
        a permutation such that ``q_map[_perm, :]`` is sorted by `i_l` (ignoring the `I_s`).
    _strides : 1D array
        strides for mapping incoming qindices `i_l` to the index of of ``q_map[_perm, :]``

    Notes
    -----
    For np.reshape, taking, for example,  :math:`i,j,... \rightarrow k` amounted to
    :math:`k = s_1*i + s_2*j + ...` for appropriate strides :math:`s_1,s_2`.

    In the charged case, however, we want to block :math:`k` by charge, so we must
    implicitly permute as well.  This reordering is encoded in `q_map`.

    Each qindex combination of the `nlegs` input legs :math:`(i_1, ..., i_{nlegs})`,
    will end up getting placed in some slice :math:`a_j:a_{j+1}` of the outgoing pipe.
    Within this slice, the data is simply reshaped in usual row-major fashion ('C'-order),
    i.e., with strides :math:`s_1 > s_2 > ...`.

    It will be a subslice of a new total block labeled by qindex :math:`I_s`.
    Because many charge combinations fuse to the same total charge,
    in general there will be many tuples :math:`(i_1, ..., i_{nlegs})` belonging to the same
    :math:`I_s`.  The rows of `q_map` are precisely the collections of
    ``[b_j, b_{j+1}, i_1, . . . , i_{nlegs}, I_s ]``,

    Here, :math:`b_j:b_{j+1}` denotes the slice of this qindex combination *within*
    the total block `I_s`, i.e., ``b_j = a_j - self.slices[I_s]``.

    The rows of map_qind are lex-sorted first by ``I_s``, then the ``i``.
    Each ``I_s`` will have multiple rows,
    and the order in which they are stored in `q_map` is the order the data is stored
    in the actual tensor, i.e., it might look like ::

        [ ...,
         [ b_j,     b_{j+1},  i_1,    ..., i_{nlegs},    I_s    ],
         [ b_{j+1}, b_{j+2},  i'_1,   ..., i'_{nlegs},   I_s    ],
         [ 0,       b_{j+3},  i''_1,  ..., i''_{nlegs},  I_s + 1],
         [ b_{j+3}, b_{j+4},  i'''_1, ..., i'''_{nlegs}, I_s + 1],
         ...]


    The charge fusion rule is::

        self.charges[Qi]*self.qconj == sum([l.charges[qi_l]*l.qconj for l in self.legs])  mod qmod

    Here the qindex ``Qi`` of the pipe corresponds to qindices ``qi_l`` on the individual legs.
    """
    cdef readonly int nlegs
    cdef readonly tuple legs
    cdef readonly tuple subshape
    cdef readonly tuple subqshape
    cdef readonly np.ndarray q_map
    cdef readonly list q_map_slices
    cdef readonly np.ndarray _perm
    cdef readonly np.ndarray _strides

    def __init__(self, legs, qconj=1, sort=True, bunch=True):
        """see help(self)"""
        chinfo = legs[0].chinfo
        # initialize LegCharge with trivial qind, which gets overwritten in _init_from_legs
        super(LegPipe, self).__init__(chinfo, [0, 1], [[0] * chinfo.qnumber], qconj)
        # additional attributes
        self.legs = legs = tuple(legs)
        self.nlegs = len(legs)
        self.subshape = tuple([l.ind_len for l in self.legs])
        self.subqshape = tuple([l.block_number for l in self.legs])
        # the diffuclt part: calculate self.slices, self.charges, self.q_map and self.q_map_slices
        self._init_from_legs(sort, bunch)
        self.test_sanity()

    def test_sanity(self):
        """Sanity check. Raises ValueErrors, if something is wrong."""
        super(LegPipe, self).test_sanity()
        assert (all([l.chinfo == self.chinfo for l in self.legs]))
        assert (self.subshape == tuple([l.ind_len for l in self.legs]))
        assert (self.subqshape == tuple([l.block_number for l in self.legs]))

    def to_LegCharge(self):
        """convert self to a LegCharge, discarding the information how to split the legs.
        Usually not needed, but called by functions, which are not implemented for a LegPipe."""
        return LegCharge(self.chinfo, self.slices, self.charges, self.qconj)

    cpdef LegPipe conj(self):
        """return a shallow copy with opposite ``self.qconj``.

        Also conjugates each of the incoming legs."""
        cdef LegPipe res = super(LegPipe, self).conj()  # invert self.qconj
        res.legs = tuple([l.conj() for l in self.legs])
        return res

    def outer_conj(self):
        """like :meth:`conj`, but don't change ``qconj`` for incoming legs."""
        res = copy.copy(self)  # shallow
        res.qconj = -1
        res._set_charges(self.chinfo.make_valid(-self.charges))
        return res

    def sort(self, *args, **kwargs):
        """convert to LegCharge and call :meth:`LegCharge.sort`"""
        # could be implemented for a LegPipe, but who needs it?
        warnings.warn("Converting LegPipe to LegCharge for `sort`")
        res = self.to_LegCharge()
        return res.sort(*args, **kwargs)

    def bunch(self, *args, **kwargs):
        """convert to LegCharge and call :meth:`LegCharge.bunch`"""
        # could be implemented for a LegPipe, but who needs it?
        warnings.warn("Converting LegPipe to LegCharge for `bunch`")
        res = self.to_LegCharge()
        return res.bunch(*args, **kwargs)

    def project(self, *args, **kwargs):
        """convert self to LegCharge and call :meth:`LegCharge.project`.

        In general, this could be implemented for a LegPipe, but would make
        :meth:`~tenpy.linalg.np_conserved.Array.split_legs` more complicated, thus we keep it
        simple.  If you really want to project and split afterwards, use the following work-around,
        which is for example used in :class:`~tenpy.algorithms.exact_diagonalization`:

        1) Create the full pipe and save it separetely.
        2) Convert the Pipe to a Leg & project the array with it.
        3) [... do calculations ...]
        4) To split the 'projected pipe' of `A`, create and empty array `B` with the legs of A,
           but replace the projected leg by the full pipe. Set `A` as a slice of `B`.
           Finally split the pipe.
        """
        warnings.warn("Converting LegPipe to LegCharge for `project`")
        res = self.to_LegCharge()
        return res.project(*args, **kwargs)

    def __str__(self):
        """fairly short debug output"""
        res_lines = [
            "LegPipe(shape {0!s}->{1:d}, ".format(self.subshape, self.ind_len),
            "    qconj {0}->{1:+1};".format(
                '(' + ', '.join(['%+d' % l.qconj for l in self.legs]) + ')', self.qconj),
            "    block numbers {0!s}->{1:d})".format(self.subqshape, self.block_number), vert_join(
                [str(l) for l in self.legs], delim=' | '), ')'
        ]
        return '\n'.join(res_lines)

    def __repr__(self):
        """full string representation"""
        return "LegPipe({legs},\nqconj={qconj:+d}, sort={s!r}, bunch={b!r})".format(
            legs='[' + ',\n'.join([repr(l) for l in self.legs]) + ']',
            qconj=self.qconj,
            s=self.sorted,
            b=self.bunched)

    @cython.wraparound(False)
    @cython.boundscheck(False)
    @cython.cdivision(True)
    cdef void _init_from_legs(LegPipe self, bint sort=True, bint bunch=True) except *:
        """calculate ``self.qind``, ``self.q_map`` and ``self.q_map_slices`` from ``self.legs``.

        `qind` is constructed to fullfill the charge fusion rule stated in the class doc-string.
        """
        # this function heavily uses numpys advanced indexing, for details see
        # `http://docs.scipy.org/doc/numpy/reference/arrays.indexing.html`_
        # and the documentation of np.mgrid
        cdef int nlegs = self.nlegs
        cdef int qnumber = self.chinfo.qnumber
        cdef np.ndarray[QTYPE_t, ndim=1] qshape = np.array(self.subqshape, dtype=QTYPE)
        cdef int i, j, sign
        cdef QTYPE_t a

        # create a grid to select the multi-index sector
        grid = np.mgrid[[slice(0, l) for l in qshape]]
        # grid is an array with shape ``(nlegs,) + qshape``,
        # with grid[li, ...] = {np.arange(qshape[li]) increasing in the li-th direcion}
        cdef np.ndarray[QTYPE_t, ndim=1] strides =  \
            np.array(grid.strides, np.intp)[1:] // grid.itemsize
        self._strides = strides  # save for :meth:`_map_incoming_qind`
        # collapse the different directions into one.
        cdef np.ndarray[QTYPE_t, ndim=2] grid2 = grid.reshape(nlegs, -1)
            # *this* is the actual `reshaping`
        # *columns* of grid are now all possible cominations of qindices.

        cdef int nblocks = grid2.shape[1]  # number of blocks in the pipe = np.product(qshape)
        cdef np.ndarray[QTYPE_t, ndim=2] q_map = np.empty((nblocks, 2 + nlegs + 1), dtype=QTYPE)
        # determine q_map -- it's essentially the grid.
        q_map[:, 2:2+nlegs] = grid2.T  # transpose -> rows are possible combinations.
        # q_map[:, :2] and q_map[:, -1] are initialized after sort/bunch.

        # determine block sizes
        cdef np.ndarray[QTYPE_t, ndim=1] blocksizes = np.ones((nblocks,), dtype=QTYPE)
        cdef np.ndarray[QTYPE_t, ndim=1] leg_bs
        for i in range(nlegs):
            leg_bs = self.legs[i]._get_block_sizes()
            for j in range(nblocks):
                blocksizes[j] *= leg_bs[grid2[i, j]]

        # calculate total charges
        cdef np.ndarray[QTYPE_t, ndim=2] charges = np.zeros((nblocks, qnumber), dtype=QTYPE)
        cdef np.ndarray[QTYPE_t, ndim=2] legcharges
        if qnumber > 0:
            for i in range(nlegs):
                legcharges = self.legs[i].charges
                sign = self.qconj * self.legs[i].qconj
                for j in range(nblocks):
                    for k in range(qnumber):
                        charges[j, k] += sign * legcharges[grid2[i, j], k]
            charges = self.chinfo.make_valid(charges)
            # now, we have what we need according to the charge **fusion rule**
            # namely for qi=`leg qindices` and li=`legs`:
            # charges[(q1, q2,...)] == self.qconj * (l1.qind[q1]*l1.qconj +
            #                                        l2.qind[q2]*l2.qconj + ...)
            charges = self.chinfo.make_valid(charges)  # modulo qmod

        if sort:
            # sort by charge. Similar code as in :meth:`LegCharge.sort`,
            # but don't want to create a copy, nor is qind[:, 0] initialized yet.
            perm_qind = lexsort(charges.T)
            q_map = q_map[perm_qind]
            charges = charges[perm_qind]
            blocksizes = blocksizes[perm_qind]
            self._perm = inverse_permutation(perm_qind)
        else:
            self._perm = None
        self._set_charges(charges)
        self.sorted = sort
        self._set_block_sizes(blocksizes)  # sets self.slices
        cdef np.ndarray[QTYPE_t, ndim=1] slices = self.slices
        for j in range(nblocks):
            q_map[j, 0] = slices[j]
            q_map[j, 1] = slices[j+1]

        cdef np.ndarray[QTYPE_t, ndim=1] idx
        if bunch:
            # call LegCharge.bunch(), which also calculates new blocksizes
            idx, bunched = super(LegPipe, self).bunch()
            self._set_charges(bunched.charges)  # copy information back to self
            self._set_slices(bunched.slices)
            a = 0
            for i in range(idx.shape[0]-1):
                for j in range(idx[i] , idx[i+1]):
                    q_map[j, 2+nlegs] = a
                a += 1
            for j in range(idx[idx.shape[0]-1], nblocks):
                q_map[j, 2+nlegs] = a
        else:
            # trivial mapping for q_map[:, -1]
            for j in range(nblocks):
                q_map[j, 2 + nlegs] = j
            idx = np.arange(len(q_map)+1, dtype=np.intp)

        # calculate the slices within blocks: subtract the start of each block
        slices = self.slices
        for j in range(nblocks):
            a = slices[q_map[j, 2 + nlegs]]
            q_map[j, 0] -= a
            q_map[j, 1] -= a

        self.q_map = q_map  # finished
        # finally calculate q_map_slices
        self.q_map_slices = [q_map[idx[i]:idx[i+1]] for i in range(len(idx)-1)]
        # q_map_slices contains only views!

    def _map_incoming_qind(self, qind_incoming):
        """map incoming qindices to indices of q_map.

        Needed for :meth:`~tenpy.linalg.np_conserved.Array.combine_legs`.

        Parameters
        ----------
        qind_incoming : 2D array
            rows are qindices :math:`(i_1, i_2, ... i_{nlegs})` for incoming legs

        Returns
        -------
        q_map_indices : 1D array
            for each row of `qind_incoming` an index `j` such that
            ``self.q_map[j, 2:-1] == qind_incoming[j]``.
        """
        assert (qind_incoming.shape[1] == self.nlegs)
        # calculate indices of q_map[_perm], which is sorted by :math:`i_1, i_2, ...`,
        # by using the appropriate strides
        inds_before_perm = np.sum(qind_incoming * self._strides[np.newaxis, :], axis=1)
        # permute them to indices in q_map
        if self._perm is None:
            return inds_before_perm  # no permutation necessary
        return self._perm[inds_before_perm]

    def __getstate__(self):
        """allow to pickle and copy"""
        super_state = super(LegPipe, self).__getstate__()
        return (super_state,
                self.nlegs,
                self.legs,
                self.subshape,
                self.subqshape,
                self.q_map,
                self.q_map_slices,
                self._perm,
                self._strides)

    cpdef void __setstate__(LegPipe self, tuple state):
        """allow to pickle and copy"""
        super_state, nlegs, legs, subshape, subqshape, q_map, q_map_slices, _perm, _strides = state
        self.nlegs = nlegs
        self.legs = legs
        self.subshape = subshape
        self.subqshape = subqshape
        self.q_map = q_map
        self.q_map_slices = q_map_slices
        self._perm = _perm
        self._strides = _strides
        super(LegPipe, self).__setstate__(super_state)

def _find_row_differences(qflat):
    """Return indices where the rows of the 2D array `qflat` change.

    Parameters
    ----------
    qflat : 2D array
        the rows of this array are compared.

    Returns
    -------
    diffs: 1D array
        The indices where rows change, including the first and last. Equivalent to:
        ``[0]+[i for i in range(1, len(qflat)) if np.any(qflat[i-1] != qflat[i])] + [len(qflat)]``
    """
    if qflat.shape[1] == 0:
        return np.array([0, qflat.shape[0]], dtype=np.intp)
    diff = np.ones(qflat.shape[0] + 1, dtype=np.bool_)
    diff[1:-1] = np.any(qflat[1:] != qflat[:-1], axis=1)
    return np.nonzero(diff)[0]  # get the indices of True-values

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.cdivision(True)
cdef _c_find_row_differences(np.ndarray[QTYPE_t,ndim=2] qflat):
    """C-version of :func:`_find_row_differences` (which uses numpy for optimization)"""
    # TODO: remove python version once np_conserved is also cythonized...
    if qflat.shape[1] == 0:
        return np.array([0, qflat.shape[0]], dtype=np.intp)
    cdef int i, j, n=1, L = qflat.shape[0], M = qflat.shape[1]
    cdef bint rows_equal = False
    res = np.empty(L + 1, dtype=np.intp)
    res[0] = 0
    for i in range(1, L):
        rows_equal = True
        for j in range(M):
            if qflat[i-1, j] != qflat[i, j]:
                rows_equal = False
                break
        if not rows_equal:
            res[n] = i
            n += 1
    res[n] = L
    return res[:n+1]
