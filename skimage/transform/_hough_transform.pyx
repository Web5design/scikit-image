#cython: cdivision=True
#cython: boundscheck=False
#cython: nonecheck=False
#cython: wraparound=False
import numpy as np

cimport numpy as cnp
from libc.math cimport abs, fabs, sqrt, ceil
from libc.stdlib cimport rand


cdef double PI_2 = 1.5707963267948966
cdef double NEG_PI_2 = -PI_2


cdef inline Py_ssize_t round(double r):
    return <Py_ssize_t>((r + 0.5) if (r > 0.0) else (r - 0.5))


def _hough(cnp.ndarray img, cnp.ndarray[ndim=1, dtype=cnp.double_t] theta=None):

    if img.ndim != 2:
        raise ValueError('The input image must be 2D.')

    # Compute the array of angles and their sine and cosine
    cdef cnp.ndarray[ndim=1, dtype=cnp.double_t] ctheta
    cdef cnp.ndarray[ndim=1, dtype=cnp.double_t] stheta

    if theta is None:
        theta = np.linspace(PI_2, NEG_PI_2, 180)

    ctheta = np.cos(theta)
    stheta = np.sin(theta)

    # compute the bins and allocate the accumulator array
    cdef cnp.ndarray[ndim=2, dtype=cnp.uint64_t] accum
    cdef cnp.ndarray[ndim=1, dtype=cnp.double_t] bins
    cdef Py_ssize_t max_distance, offset

    max_distance = 2 * <Py_ssize_t>ceil(sqrt(img.shape[0] * img.shape[0] +
                                             img.shape[1] * img.shape[1]))
    accum = np.zeros((max_distance, theta.shape[0]), dtype=np.uint64)
    bins = np.linspace(-max_distance / 2.0, max_distance / 2.0, max_distance)
    offset = max_distance / 2

    # compute the nonzero indexes
    cdef cnp.ndarray[ndim=1, dtype=cnp.npy_intp] x_idxs, y_idxs
    y_idxs, x_idxs = np.nonzero(img)

    # finally, run the transform
    cdef Py_ssize_t nidxs, nthetas, i, j, x, y, accum_idx
    nidxs = y_idxs.shape[0] # x and y are the same shape
    nthetas = theta.shape[0]
    for i in range(nidxs):
        x = x_idxs[i]
        y = y_idxs[i]
        for j in range(nthetas):
            accum_idx = <int>round((ctheta[j] * x + stheta[j] * y)) + offset
            accum[accum_idx, j] += 1
    return accum, theta, bins


def _probabilistic_hough(cnp.ndarray img, int value_threshold,
                         int line_length, int line_gap,
                         cnp.ndarray[ndim=1, dtype=cnp.double_t] theta=None):

    if img.ndim != 2:
        raise ValueError('The input image must be 2D.')

    if theta is None:
        theta = PI_2 - np.arange(180) / 180.0 * 2 * PI_2

    cdef Py_ssize_t height = img.shape[0]
    cdef Py_ssize_t width = img.shape[1]

    # compute the bins and allocate the accumulator array
    cdef cnp.ndarray[ndim=2, dtype=cnp.int64_t] accum
    cdef cnp.ndarray[ndim=1, dtype=cnp.double_t] ctheta, stheta
    cdef cnp.ndarray[ndim=2, dtype=cnp.uint8_t] mask = \
         np.zeros((height, width), dtype=np.uint8)
    cdef cnp.ndarray[ndim=2, dtype=cnp.int32_t] line_end = \
         np.zeros((2, 2), dtype=np.int32)
    cdef Py_ssize_t max_distance, offset, num_indexes, index
    cdef double a, b
    cdef Py_ssize_t nidxs, i, j, x, y, px, py, accum_idx
    cdef int value, max_value, max_theta
    cdef int shift = 16
    # maximum line number cutoff
    cdef Py_ssize_t lines_max = 2 ** 15
    cdef Py_ssize_t xflag, x0, y0, dx0, dy0, dx, dy, gap, x1, y1, \
                    good_line, count
    cdef list lines = list()

    max_distance = 2 * <int>ceil((sqrt(img.shape[0] * img.shape[0] +
                                       img.shape[1] * img.shape[1])))
    accum = np.zeros((max_distance, theta.shape[0]), dtype=np.int64)
    offset = max_distance / 2
    nthetas = theta.shape[0]

    # compute sine and cosine of angles
    ctheta = np.cos(theta)
    stheta = np.sin(theta)

    # find the nonzero indexes
    y_idxs, x_idxs = np.nonzero(img)
    points = list(zip(x_idxs, y_idxs))
    # mask all non-zero indexes
    mask[y_idxs, x_idxs] = 1

    while 1:

        # quit if no remaining points
        count = len(points)
        if count == 0:
            break

        # select random non-zero point
        index = rand() % count
        x = points[index][0]
        y = points[index][1]
        del points[index]

        # if previously eliminated, skip
        if not mask[y, x]:
            continue

        value = 0
        max_value = value_threshold - 1
        max_theta = -1

        # apply hough transform on point
        for j in range(nthetas):
            accum_idx = <int>round((ctheta[j] * x + stheta[j] * y)) + offset
            accum[accum_idx, j] += 1
            value = accum[accum_idx, j]
            if value > max_value:
                max_value = value
                max_theta = j
        if max_value < value_threshold:
            continue

        # from the random point walk in opposite directions and find line
        # beginning and end
        a = -stheta[max_theta]
        b = ctheta[max_theta]
        x0 = x
        y0 = y
        # calculate gradient of walks using fixed point math
        xflag = fabs(a) > fabs(b)
        if xflag:
            if a > 0:
                dx0 = 1
            else:
                dx0 = -1
            dy0 = <int>round(b * (1 << shift) / fabs(a))
            y0 = (y0 << shift) + (1 << (shift - 1))
        else:
            if b > 0:
                dy0 = 1
            else:
                dy0 = -1
            dx0 = <int>round(a * (1 << shift) / fabs(b))
            x0 = (x0 << shift) + (1 << (shift - 1))

        # pass 1: walk the line, merging lines less than specified gap length
        for k in range(2):
            gap = 0
            px = x0
            py = y0
            dx = dx0
            dy = dy0
            if k > 0:
                dx = -dx
                dy = -dy
            while 1:
                if xflag:
                    x1 = px
                    y1 = py >> shift
                else:
                    x1 = px >> shift
                    y1 = py;
                # check when line exits image boundary
                if x1 < 0 or x1 >= width or y1 < 0 or y1 >= height:
                    break
                gap += 1
                # if non-zero point found, continue the line
                if mask[y1, x1]:
                    gap = 0;
                    line_end[k, 1] = y1
                    line_end[k, 0] = x1
                # if gap to this point was too large, end the line
                elif gap > line_gap:
                    break
                px += dx
                py += dy
        # confirm line length is sufficient
        good_line = abs(line_end[1, 1] - line_end[0, 1]) >= line_length or \
                    abs(line_end[1, 0] - line_end[0, 0]) >= line_length

        # pass 2: walk the line again and reset accumulator and mask
        for k in range(2):
            px = x0
            py = y0
            dx = dx0
            dy = dy0
            if k > 0:
                dx = -dx
                dy = -dy
            while 1:
                if xflag:
                    x1 = px
                    y1 = py >> shift
                else:
                    x1 = px >> shift
                    y1 = py
                # if non-zero point found, continue the line
                if mask[y1, x1]:
                    if good_line:
                        accum_idx = <int>round((ctheta[j] * x1 \
                                                + stheta[j] * y1)) + offset
                        accum[accum_idx, max_theta] -= 1
                        mask[y1, x1] = 0
                # exit when the point is the line end
                if x1 == line_end[k, 0] and y1 == line_end[k, 1]:
                    break
                px += dx
                py += dy

        # add line to the result
        if good_line:
            lines.append(((line_end[0, 0], line_end[0, 1]),
                          (line_end[1, 0], line_end[1, 1])))
            if len(lines) > lines_max:
                return lines

    return lines
